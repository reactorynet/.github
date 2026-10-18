#!/usr/bin/env bash
#
# sync-pr-template.sh — propagate the canonical Reactory pull request template
# to every Reactory repository and submodule.
#
#   Canonical source : <this repo>/standards/pull_request_template.md
#   Destination      : <repo>/.github/pull_request_template.md
#
# Usage:
#   ./scripts/sync-pr-template.sh                 # report drift only (safe, default)
#   ./scripts/sync-pr-template.sh --apply         # write the template where it differs
#   ./scripts/sync-pr-template.sh --check         # explicit check mode (exit 1 on drift)
#   ./scripts/sync-pr-template.sh --apply --only reactory-docs
#   ./scripts/sync-pr-template.sh --base /Users/me/Projects/reactory
#
# Worktree layout (one checkout per repo beside this repo):
#   ./scripts/sync-pr-template.sh --apply \
#       --base ../.. \
#       --prefix REACTORY-302016408-
#
# Exit codes:
#   0  everything in sync (or --apply completed)
#   1  drift detected in --check mode
#   2  setup problem (missing canonical source or base directory)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$REPO_ROOT/standards/pull_request_template.md"
TARGET_REL=".github/pull_request_template.md"

MODE="check"
BASE_DIR="${REACTORY_BASE:-$(cd "$REPO_ROOT/.." && pwd)}"
PREFIX="${REACTORY_WORKTREE_PREFIX:-}"
ONLY=""
QUIET=0

# Target specs. Format: "<path relative to base>[=<directory name>]".
# The optional directory name is only needed when the checkout lives under a
# different name than the repository (worktrees, submodules).
TARGETS="
reactory-express-server
reactory-pwa-client
reactory-core
reactory-docs
reactory-data
reactory-compute-service
reactory-workflow-es
reactory-speech-service
reactory-electron
reactory-native
reactory-express-server/config/reactory=express-server-devops
reactory-pwa-client/src/components/plugins/reactory-core=client-core-pwa-plugin
"

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)  MODE="apply" ;;
    --check)  MODE="check" ;;
    --base)   shift; BASE_DIR="${1:-}" ;;
    --prefix) shift; PREFIX="${1:-}" ;;
    --only)   shift; ONLY="${1:-}" ;;
    --quiet)  QUIET=1 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$SOURCE" ] || { echo "✗ Canonical template not found: $SOURCE" >&2; exit 2; }
[ -d "$BASE_DIR" ] || { echo "✗ Base directory not found: $BASE_DIR" >&2; exit 2; }

say() { [ "$QUIET" -eq 1 ] || echo "$@"; }

in_sync=0; updated=0; drift=0; unavailable=0; filtered=0
drift_list=""

process_target() {
  local spec="$1"
  local rel="${spec%%=*}"
  local dirname="${spec#*=}"
  [ "$dirname" = "$spec" ] && dirname="$rel"

  case "$dirname" in
    */*) dirname="$(basename "$dirname")" ;;
  esac

  local dir="$BASE_DIR/$PREFIX$dirname"
  local label="$rel"

  if [ -n "$ONLY" ]; then
    case "$rel" in
      *"$ONLY"*) : ;;
      *) filtered=$((filtered + 1)); return 0 ;;
    esac
  fi

  if [ ! -d "$dir" ]; then
    printf '  %-50s %s\n' "$label" "MISSING (not cloned)"
    unavailable=$((unavailable + 1))
    return 0
  fi

  # Accept real checkouts (.git directory) and submodule worktrees (.git file).
  if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
    printf '  %-50s %s\n' "$label" "NOT A GIT REPO (skipped)"
    unavailable=$((unavailable + 1))
    return 0
  fi

  local dest="$dir/$TARGET_REL"

  if [ -f "$dest" ] && cmp -s "$SOURCE" "$dest"; then
    printf '  %-50s %s\n' "$label" "in sync"
    in_sync=$((in_sync + 1))
    return 0
  fi

  if [ "$MODE" = "check" ]; then
    if [ -f "$dest" ]; then
      printf '  %-50s %s\n' "$label" "DRIFT"
    else
      printf '  %-50s %s\n' "$label" "MISSING $TARGET_REL"
    fi
    drift=$((drift + 1))
    drift_list="$drift_list$rel "
    return 0
  fi

  mkdir -p "$dir/.github" || { printf '  %-50s %s\n' "$label" "ERROR creating .github"; unavailable=$((unavailable + 1)); return 0; }
  if cp "$SOURCE" "$dest"; then
    printf '  %-50s %s\n' "$label" "UPDATED"
    updated=$((updated + 1))
  else
    printf '  %-50s %s\n' "$label" "ERROR writing"
    unavailable=$((unavailable + 1))
  fi
}

say "Reactory PR template sync"
say "  source : $SOURCE"
say "  base   : $BASE_DIR${PREFIX:+ (prefix: $PREFIX)}"
say "  mode   : $MODE"
say ""

for spec in $TARGETS; do process_target "$spec"; done

say ""
say "Summary: $in_sync in sync, $updated updated, $drift drifted/missing, $unavailable unavailable, $filtered filtered"

if [ "$MODE" = "check" ] && [ "$drift" -gt 0 ]; then
  say ""
  say "Drift detected in: $drift_list"
  say "Run with --apply to bring these repositories in line."
  exit 1
fi

exit 0
