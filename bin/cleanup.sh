#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: cleanup.sh --lock PATH

Removes a lock directory created by nightly_codex.sh.
USAGE
}

LOCK_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lock) LOCK_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$LOCK_PATH" ]] || die "--lock is required"

if [[ -d "$LOCK_PATH" ]]; then
  rm -rf "$LOCK_PATH"
  log "removed lock: $LOCK_PATH"
else
  log "lock already absent: $LOCK_PATH"
fi
