#!/usr/bin/env bash
#
# gpg-setup.sh — configure GPG commit signing for a Reactory developer workstation.
#
# Creates (or reuses) a signing key, wires git to use it, configures gpg-agent
# caching, exports the public key and — when the GitHub CLI is available —
# uploads it so commits render as "Verified".
#
# Usage:
#   ./scripts/gpg-setup.sh --name "Werner Weber" --email you@example.com
#   ./scripts/gpg-setup.sh --email you@example.com --algo ed25519 --no-upload
#   ./scripts/gpg-setup.sh --email you@example.com --existing 0xABCDEF0123456789
#
# The passphrase is read from the terminal (never from argv, never written to
# shell history). Press Enter for an empty passphrase — not recommended.
#
set -euo pipefail

NAME=""
EMAIL=""
ALGO="rsa4096"
EXISTING=""
UPLOAD=1
SCOPE="global"

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)     shift; NAME="${1:-}" ;;
    --email)    shift; EMAIL="${1:-}" ;;
    --algo)     shift; ALGO="${1:-}" ;;
    --existing) shift; EXISTING="${1:-}" ;;
    --no-upload) UPLOAD=0 ;;
    --local)    SCOPE="local" ;;
    -h|--help)  usage ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
info "Preflight"
command -v gpg >/dev/null 2>&1 || die "gpg not found. Install it first: brew install gnupg pinentry-mac"
GPG_MAJOR=$(gpg --version | awk '/^gpg \(GnuPG\)/ {split($3, v, "."); print v[1]; exit}')
[ "${GPG_MAJOR:-0}" -ge 2 ] || die "GnuPG 2.x or newer required (found: $(gpg --version | head -1))"
ok "gpg $(gpg --version | head -1 | awk '{print $3}')"

if [ -z "$NAME" ]; then
  NAME=$(git config --global user.name || true)
  [ -n "$NAME" ] || read -r -p "Full name for the key UID: " NAME
fi
if [ -z "$EMAIL" ]; then
  EMAIL=$(git config --global user.email || true)
  [ -n "$EMAIL" ] || read -r -p "Email for the key UID: " EMAIL
fi
[ -n "$NAME" ] && [ -n "$EMAIL" ] || die "Both --name and --email are required."
ok "UID: $NAME <$EMAIL>"

UID_STR="$NAME <$EMAIL>"
FPR=""

# ------------------------------------------------------------- key creation --
if [ -n "$EXISTING" ]; then
  info "Using existing secret key $EXISTING"
  FPR=$(gpg --list-secret-keys --with-colons "$EXISTING" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')
  [ -n "$FPR" ] || die "No secret key found matching $EXISTING"
else
  FPR=$(gpg --list-secret-keys --with-colons "$EMAIL" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}' || true)
  if [ -n "$FPR" ]; then
    info "Reusing existing secret key for $EMAIL"
  else
    info "Generating a new $ALGO signing key (no expiry)"
    echo "    Choose a strong passphrase. It will not be echoed or logged."

    PASSFILE=$(mktemp "${TMPDIR:-/tmp}/reactory-gpg-pass.XXXXXX")
    chmod 600 "$PASSFILE"
    cleanup() { rm -f "$PASSFILE" 2>/dev/null || true; }
    trap cleanup EXIT INT TERM

    printf "    Passphrase: "; read -r -s PASS1; echo
    printf "    Confirm   : "; read -r -s PASS2; echo
    [ "$PASS1" = "$PASS2" ] || die "Passphrases did not match."
    [ -n "$PASS1" ] || warn "Using an empty passphrase — the key is unprotected on this machine."
    printf '%s' "$PASS1" > "$PASSFILE"
    unset PASS1 PASS2

    gpg --batch --pinentry-mode loopback --passphrase-file "$PASSFILE" \
        --quick-generate-key "$UID_STR" "$ALGO" default 0 >/dev/null 2>&1 \
      || die "Key generation failed. Re-run manually to see the full error."

    FPR=$(gpg --list-secret-keys --with-colons "$EMAIL" | awk -F: '/^fpr:/ {print $10; exit}')
    [ -n "$FPR" ] || die "Key was created but its fingerprint could not be resolved."
  fi
fi
ok "Signing key: $FPR"

# --------------------------------------------------------------- gpg-agent --
info "Configuring gpg-agent (passphrase caching, macOS pinentry)"
GNUPGHOME_DIR="${GNUPGHOME:-$HOME/.gnupg}"
mkdir -p "$GNUPGHOME_DIR"
chmod 700 "$GNUPGHOME_DIR"
AGENT_CONF="$GNUPGHOME_DIR/gpg-agent.conf"
touch "$AGENT_CONF"
chmod 600 "$AGENT_CONF"

grep -q '^default-cache-ttl ' "$AGENT_CONF" || echo "default-cache-ttl 28800" >> "$AGENT_CONF"
grep -q '^max-cache-ttl '     "$AGENT_CONF" || echo "max-cache-ttl 86400"     >> "$AGENT_CONF"
if [ "$(uname -s)" = "Darwin" ] && command -v pinentry-mac >/dev/null 2>&1; then
  grep -q '^pinentry-program ' "$AGENT_CONF" || \
    echo "pinentry-program $(command -v pinentry-mac)" >> "$AGENT_CONF"
  ok "pinentry-mac registered"
else
  warn "pinentry-mac not found — install with: brew install pinentry-mac"
fi
gpgconf --kill gpg-agent >/dev/null 2>&1 || true
gpg-connect-agent /bye >/dev/null 2>&1 || true
ok "gpg-agent restarted"

# --------------------------------------------------------------- git config --
info "Configuring git ($SCOPE)"
if [ "$SCOPE" = "global" ]; then GIT="git config --global"; else GIT="git config"; fi
$GIT user.name  "$NAME"
$GIT user.email "$EMAIL"
$GIT user.signingkey "$FPR"
$GIT commit.gpgsign true
$GIT tag.gpgsign true
$GIT gpg.program "$(command -v gpg)"
$GIT gpg.format openpgp
ok "user.signingkey, commit.gpgsign, tag.gpgsign, gpg.program set"

# ---------------------------------------------------------------- public key --
info "Exporting public key"
KEYFILE="$GNUPGHOME_DIR/reactory-signing-key-$FPR.asc"
gpg --armor --export "$FPR" > "$KEYFILE"
ok "$KEYFILE"

# ------------------------------------------------------------------- upload --
if [ "$UPLOAD" -eq 1 ]; then
  info "Registering public key with GitHub"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh api user/gpg_keys --paginate -q '.[].raw_key' 2>/dev/null | grep -qF "$(sed -n '2p' "$KEYFILE")"; then
      ok "Key already present on GitHub"
    else
      if gh api user/gpg_keys -f "armored_public_key=$(cat "$KEYFILE")" >/dev/null 2>&1; then
        ok "Public key uploaded to GitHub"
      else
        warn "Upload failed. Add it manually: https://github.com/settings/gpg/new"
      fi
    fi
  else
    warn "gh CLI unavailable or not authenticated — upload manually:"
    echo "      https://github.com/settings/gpg/new"
  fi
  echo ""
  echo "  Important: the key UID email ($EMAIL) must be a verified email on the"
  echo "  GitHub account, otherwise commits show as 'Unverified'."
fi

echo ""
info "Done. Verify with: ./scripts/gpg-verify.sh"
