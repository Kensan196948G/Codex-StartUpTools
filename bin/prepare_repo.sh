#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: prepare_repo.sh --repo PATH --base BRANCH --branch BRANCH [--dry-run]

Validates a Git repository and prepares the nightly branch.
USAGE
}

REPO_PATH=""
BASE_BRANCH="main"
NIGHTLY_BRANCH=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_PATH="$2"; shift 2 ;;
    --base) BASE_BRANCH="$2"; shift 2 ;;
    --branch) NIGHTLY_BRANCH="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$REPO_PATH" ]] || die "--repo is required"
[[ -n "$NIGHTLY_BRANCH" ]] || die "--branch is required"
[[ -d "$REPO_PATH" ]] || die "repository path not found: $REPO_PATH"

require_command git
git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git repository: $REPO_PATH"

if [[ "$DRY_RUN" == "true" ]]; then
  log "dry-run: repository is valid: $REPO_PATH"
  log "dry-run: would prepare branch $NIGHTLY_BRANCH from $BASE_BRANCH"
  exit 0
fi

if git -C "$REPO_PATH" remote | grep -q .; then
  git -C "$REPO_PATH" fetch --prune
fi

if git -C "$REPO_PATH" show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then
  git -C "$REPO_PATH" checkout "$BASE_BRANCH"
elif git -C "$REPO_PATH" show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH"; then
  git -C "$REPO_PATH" checkout -B "$BASE_BRANCH" "origin/$BASE_BRANCH"
else
  die "base branch not found locally or on origin: $BASE_BRANCH"
fi

git -C "$REPO_PATH" checkout -B "$NIGHTLY_BRANCH"
log "prepared $REPO_PATH on $NIGHTLY_BRANCH"
