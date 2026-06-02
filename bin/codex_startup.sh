#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/startup.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/model_usage.sh"

usage() {
  cat <<'USAGE'
Usage: codex_startup.sh [options]

Launches Codex for a selected Linux project and records startup history.

Options:
  --project PATH|NAME  Project path or name under PROJECTS_DIR.
  --base-dir DIR       Project base directory. Default: /home/kensan/Projects.
  --dry-run            Print the launch plan only.
  --full-auto          Add non-interactive full-auto defaults for Codex.
  --profile NAME       Use a named Codex profile from ~/.codex/config.toml.
  --exec PROMPT        Run `codex exec` with PROMPT instead of interactive Codex.
  --task FILE          Run `codex exec` feeding FILE as the goal prompt via stdin.
  --interactive        With --task: launch interactive TUI with FILE as the initial goal prompt.
  --model-auto         Auto-select model via model_usage.sh failover (records usage after run).
  --                  Remaining args are passed to Codex.
  -h, --help           Show this help.
USAGE
}

PROJECT=""
BASE_DIR=""
DRY_RUN="false"
FULL_AUTO="false"
PROFILE=""
EXEC_PROMPT=""
TASK_FILE=""
INTERACTIVE_MODE="false"
MODEL_AUTO="false"
SELECTED_MODEL=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --full-auto) FULL_AUTO="true"; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --exec) EXEC_PROMPT="$2"; shift 2 ;;
    --task) TASK_FILE="$2"; shift 2 ;;
    --interactive) INTERACTIVE_MODE="true"; shift ;;
    --model-auto) MODEL_AUTO="true"; shift ;;
    --) shift; EXTRA_ARGS+=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

load_startup_config
if [[ -n "$BASE_DIR" ]]; then
  # Used by resolve_project_path from lib/startup.sh.
  # shellcheck disable=SC2034
  PROJECTS_DIR="$BASE_DIR"
fi

if [[ -z "$PROJECT" && -t 0 ]]; then
  PROJECT_PATH="$(select_project_interactive)"
else
  PROJECT_PATH="$(resolve_project_path "$PROJECT")"
fi

[[ -d "$PROJECT_PATH" ]] || die "project directory not found: $PROJECT_PATH"
require_command "$CODEX_COMMAND"
if [[ -n "$TASK_FILE" ]]; then
  [[ -f "$TASK_FILE" ]] || die "task file not found: $TASK_FILE"
fi

if [[ "$MODEL_AUTO" == "true" ]]; then
  SELECTED_MODEL="$(model_usage_select)"
fi

ARGS=()
if [[ -n "$CODEX_ARGS" ]]; then
  read -r -a DEFAULT_CODEX_ARGS <<<"$CODEX_ARGS"
  ARGS+=("${DEFAULT_CODEX_ARGS[@]}")
fi
if [[ -n "$PROFILE" ]]; then
  ARGS+=("-p" "$PROFILE")
fi
if [[ -n "$SELECTED_MODEL" ]]; then
  ARGS+=("-m" "$SELECTED_MODEL")
fi
if [[ "$FULL_AUTO" == "true" ]]; then
  ARGS+=("-a" "never" "-s" "workspace-write")
fi

if [[ -n "$EXEC_PROMPT" ]]; then
  ARGS+=("--no-alt-screen" "exec" "-C" "$PROJECT_PATH")
  ARGS+=("${EXTRA_ARGS[@]}")
  ARGS+=("$EXEC_PROMPT")
elif [[ -n "$TASK_FILE" && "$INTERACTIVE_MODE" == "true" ]]; then
  # Interactive TUI with goal prompt as the initial message (fully autonomous)
  ARGS+=("-C" "$PROJECT_PATH")
  ARGS+=("${EXTRA_ARGS[@]}")
elif [[ -n "$TASK_FILE" ]]; then
  ARGS+=("--no-alt-screen" "exec" "-C" "$PROJECT_PATH")
  ARGS+=("${EXTRA_ARGS[@]}")
  ARGS+=("-")
else
  ARGS+=("-C" "$PROJECT_PATH")
  ARGS+=("${EXTRA_ARGS[@]}")
fi

printf 'Codex Launch Plan\n'
printf '  Project : %s\n' "$PROJECT_PATH"
if [[ -n "$TASK_FILE" ]]; then
  printf '  Task    : %s\n' "$TASK_FILE"
  if [[ "$INTERACTIVE_MODE" == "true" ]]; then
    printf '  Mode    : %s\n' "interactive TUI (goal prompt auto-submit)"
  else
    printf '  Mode    : %s\n' "exec (batch)"
  fi
fi
if [[ -n "$SELECTED_MODEL" ]]; then
  _plan_rem="$(_model_remaining_seconds "$SELECTED_MODEL")"
  _plan_pct=$(( _plan_rem * 100 / MODEL_SESSION_LIMIT ))
  printf '  Model   : %s (auto-selected, %d%% remaining)\n' "$SELECTED_MODEL" "$_plan_pct"
fi
printf '  Command : %s' "$CODEX_COMMAND"
printf ' %q' "${ARGS[@]}"
if [[ -n "$TASK_FILE" && "$INTERACTIVE_MODE" == "true" ]]; then
  printf ' "<task-file-content>"'
fi
printf '\n'

if [[ "$DRY_RUN" == "true" ]]; then
  record_recent_project "$PROJECT_PATH" "dry-run" 0
  exit 0
fi

started_ms="$(date '+%s%3N')"
log_file="$STARTUP_LOG_DIR/codex-startup-$(project_name_from_path "$PROJECT_PATH")-$(date '+%Y%m%d-%H%M%S').log"
set +e
if [[ -n "$TASK_FILE" && "$INTERACTIVE_MODE" == "true" ]]; then
  initial_prompt="$(cat "$TASK_FILE")"
  (
    cd "$PROJECT_PATH"
    "$CODEX_COMMAND" "${ARGS[@]}" "$initial_prompt"
  )
elif [[ -n "$TASK_FILE" ]]; then
  ( cd "$PROJECT_PATH" && "$CODEX_COMMAND" "${ARGS[@]}" ) <"$TASK_FILE"
else
  (
    cd "$PROJECT_PATH"
    "$CODEX_COMMAND" "${ARGS[@]}"
  )
fi
exit_code=$?
set -e
printf '[%s] exit_code=%d project=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$exit_code" "$PROJECT_PATH" >"$log_file"

ended_ms="$(date '+%s%3N')"
elapsed_ms="$((ended_ms - started_ms))"
if [[ "$exit_code" -eq 0 ]]; then
  record_recent_project "$PROJECT_PATH" "success" "$elapsed_ms"
else
  record_recent_project "$PROJECT_PATH" "failure" "$elapsed_ms"
fi
if [[ "$MODEL_AUTO" == "true" && -n "$SELECTED_MODEL" ]]; then
  model_usage_record "$SELECTED_MODEL" "$(( elapsed_ms / 1000 ))" "$exit_code" "$log_file"
fi

exit "$exit_code"
