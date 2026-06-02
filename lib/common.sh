#!/usr/bin/env bash

set -euo pipefail

AI_NIGHTLY_ROOT="${AI_NIGHTLY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

ensure_dir() {
  mkdir -p "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

sanitize_name() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-'
}

load_config() {
  local config_file="$1"
  if [[ -n "$config_file" ]]; then
    [[ -f "$config_file" ]] || die "config file not found: $config_file"
    # shellcheck source=/dev/null
    source "$config_file"
  fi
}

write_meta() {
  local file="$1"
  local key="$2"
  local value="$3"
  printf '%s=%q\n' "$key" "$value" >>"$file"
}

read_meta_value() {
  local file="$1"
  local key="$2"
  local line
  line="$(grep -E "^${key}=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 1
  printf '%s\n' "${line#*=}"
}

run_logged() {
  local label="$1"
  local outfile="$2"
  shift 2

  {
    printf '\n## %s\n' "$label"
    printf '$'
    printf ' %q' "$@"
    printf '\n'
  } >>"$outfile"

  "$@" >>"$outfile" 2>&1
}
