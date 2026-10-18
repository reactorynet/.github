#!/usr/bin/env bash
#
# gpg-verify.sh — audit GPG commit-signing readiness on this workstation.
#
# Checks: gpg availability, secret key, git configuration, a real end-to-end
# sign-and-verify cycle, and whether the public key is registered on GitHub.
#
# Usage:
#   ./scripts/gpg-verify.sh
#   ./scripts/gpg-verify.sh --repo /path/to/repo    # audit effective repo config
#   ./scripts/gpg-verify.sh --repo . --no-remote    # offline / CI: skip GitHub checks
#   ./scripts/gpg-verify.sh --json
#
# Exit code 0 when every required check passes, 1 otherwise.
#
set -uo pipefail

REPO=""
JSON=0
REMOTE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) shift; REPO="${1:-}" ;;
    --json) JSON=1 ;;
    --no-remote) REMOTE=0 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

PASS=0; FAIL=0; WARN=0
RESULTS=""

record() { # status|label|detail
  case "$1" in
    PASS) PASS=$((PASS + 1)); icon="✓";;
    FAIL) FAIL=$((FAIL + 1)); icon="✗";;
    WARN) WARN=$((WARN + 1)); icon="!";;
  esac
  [ "$JSON" -eq 0 ] && printf '  %s %-34s %s\n' "$icon" "$2" "$3"
  RESULTS="$RESULTS$1|$2|$3\n"
}

[ "$JSON" -eq 0 ] && echo "Reactory GPG commit-signing audit" && echo ""

# --------------------------------------------------------------- 1. tooling --
if command -v gpg >/dev/null 2>&1; then
  record PASS "gpg installed" "$(gpg --version | head -1 | awk '{print $3}')"
else
  record FAIL "gpg installed" "not found — run: brew install gnupg pinentry-mac"
  [ "$JSON" -eq 0 ] && { echo ""; echo "Cannot continue without gpg."; exit 1; }
fi

if command -v pinentry-mac >/dev/null 2>&1; then
  record PASS "pinentry-mac" "$(command -v pinentry-mac)"
else
  record WARN "pinentry-mac" "not found — passphrase prompts may fall back to tty"
fi

# Config resolution: when --repo is given, read the effective value for that
# repository (local overrides global, exactly as git itself resolves it).
gitcfg() {
  if [ -n "$REPO" ]; then git -C "$REPO" config --get "$1"; else git config --global --get "$1"; fi
}
SCOPE_LABEL="global"
[ -n "$REPO" ] && SCOPE_LABEL="effective"

# ----------------------------------------------------------------- 2. keys --
EMAIL=$(gitcfg user.email || true)
if [ -n "$EMAIL" ] && gpg --list-secret-keys "$EMAIL" >/dev/null 2>&1; then
  FPR=$(gpg --list-secret-keys --with-colons "$EMAIL" | awk -F: '/^fpr:/ {print $10; exit}')
  record PASS "secret key for $EMAIL" "$FPR"
else
  FPR=""
  record FAIL "secret key" "none for '${EMAIL:-<no user.email set>}' — run gpg-setup.sh"
fi

# ------------------------------------------------------------ 3. git config --
for key in user.signingkey commit.gpgsign gpg.program; do
  val=$(gitcfg "$key" || true)
  if [ -n "$val" ]; then record PASS "git $key ($SCOPE_LABEL)" "$val"; else record FAIL "git $key ($SCOPE_LABEL)" "unset"; fi
done

if [ -n "$REPO" ]; then
  local_gpgsign=$(git -C "$REPO" config --local --get commit.gpgsign 2>/dev/null || true)
  case "$local_gpgsign" in
    true)  record PASS "repo-local commit.gpgsign" "true";;
    "")    record PASS "repo-local commit.gpgsign" "unset (inherits global)";;
    *)     record FAIL "repo-local commit.gpgsign" "$local_gpgsign";;
  esac
fi

# --------------------------------------------------------- 4. signing cycle --
TMP=$(mktemp -d "${TMPDIR:-/tmp}/reactory-sign-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

if [ -n "$FPR" ]; then
  (
    cd "$TMP" || exit 1
    git init -q . || exit 1
    git config user.name  "$(gitcfg user.name || echo Test)"
    git config user.email "${EMAIL:-test@example.com}"
    git config user.signingkey "$FPR"
    git config gpg.program "$(command -v gpg)"
    echo ok > test.txt
    git add test.txt
    git commit -S -q -m "test: signing smoke test" >/dev/null 2>&1 || exit 1
    git log --show-signature -1 2>&1 | grep -q "Good signature" || exit 1
  )
  if [ $? -eq 0 ]; then
    record PASS "sign + verify round trip" "Good signature"
  else
    record FAIL "sign + verify round trip" "commit signing failed — see docs troubleshooting"
  fi
else
  record WARN "sign + verify round trip" "skipped (no key)"
fi

# -------------------------------------------------------------- 5. GitHub ---
if [ "$REMOTE" -eq 0 ]; then
  record WARN "GitHub registration" "skipped (--no-remote)"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  COUNT=$(gh api user/gpg_keys --paginate -q 'length' 2>/dev/null || echo 0)
  if [ "$COUNT" -gt 0 ] 2>/dev/null; then
    record PASS "GitHub GPG keys" "$COUNT registered"
  else
    record FAIL "GitHub GPG keys" "none registered — https://github.com/settings/gpg/new"
  fi
  GH_EMAILS=$(gh api user/emails -q '[.[] | select(.verified) | .email] | join(",")' 2>/dev/null || echo "")
  if [ -n "$EMAIL" ] && echo ",$GH_EMAILS," | grep -qF ",$EMAIL,"; then
    record PASS "GitHub verified email" "$EMAIL"
  elif [ -n "$GH_EMAILS" ]; then
    record WARN "GitHub verified email" "$EMAIL not verified on GitHub — commits will show Unverified"
  else
    record WARN "GitHub verified email" "could not query (token may lack user:email scope)"
  fi
else
  record WARN "GitHub registration" "gh unavailable — check https://github.com/settings/gpg_keys"
fi

# --------------------------------------------------------------- summary ----
if [ "$JSON" -eq 1 ]; then
  printf '{"pass":%d,"fail":%d,"warn":%d,"checks":[' "$PASS" "$FAIL" "$WARN"
  first=1
  printf '%b' "$RESULTS" | while IFS='|' read -r status label detail; do
    [ -z "$status" ] && continue
    [ "$first" -eq 0 ] && printf ','
    first=0
    printf '{"status":"%s","check":"%s","detail":"%s"}' \
      "$status" "$(printf '%s' "$label" | sed 's/"/\\"/g')" "$(printf '%s' "$detail" | sed 's/"/\\"/g')"
  done
  printf ']}\n'
else
  echo ""
  echo "Summary: $PASS passed, $FAIL failed, $WARN warnings"
  [ "$FAIL" -gt 0 ] && echo "Signing is NOT ready. Fix the ✗ items above."
  [ "$FAIL" -eq 0 ] && echo "Signing is ready. New commits on this machine will be signed."
fi

[ "$FAIL" -gt 0 ] && exit 1
exit 0
