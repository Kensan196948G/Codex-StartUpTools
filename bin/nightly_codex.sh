#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: nightly_codex.sh [options]

Options:
  --config FILE       Load job configuration (default: config/jobs.conf if present)
  --repo PATH         Target Git repository path
  --repo-name NAME    Logical repository name
  --task FILE         Markdown task prompt for Codex
  --base BRANCH       Base branch (default: main)
  --max-runtime DUR   timeout duration, e.g. 5h or 30m
  --pr-mode MODE      off, draft-file, or gh-draft
  --dry-run           Validate configuration without changing the target repository
  --skip-codex        Prepare/report without invoking Codex; useful for tests
  -h, --help          Show this help
USAGE
}

CONFIG_FILE="$AI_NIGHTLY_ROOT/config/jobs.conf"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE=""

CLI_REPO_PATH=""
CLI_REPO_NAME=""
CLI_TASK_FILE=""
CLI_BASE_BRANCH=""
CLI_MAX_RUNTIME=""
CLI_PR_MODE=""
DRY_RUN="false"
SKIP_CODEX="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --repo) CLI_REPO_PATH="$2"; shift 2 ;;
    --repo-name) CLI_REPO_NAME="$2"; shift 2 ;;
    --task) CLI_TASK_FILE="$2"; shift 2 ;;
    --base) CLI_BASE_BRANCH="$2"; shift 2 ;;
    --max-runtime) CLI_MAX_RUNTIME="$2"; shift 2 ;;
    --pr-mode) CLI_PR_MODE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --skip-codex) SKIP_CODEX="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_config "$CONFIG_FILE"

REPO_PATH="${CLI_REPO_PATH:-${REPO_PATH:-}}"
REPO_NAME="${CLI_REPO_NAME:-${REPO_NAME:-$(basename "${REPO_PATH:-repo}")}}"
TASK_FILE="${CLI_TASK_FILE:-${TASK_FILE:-$AI_NIGHTLY_ROOT/tasks/codex_goal_prompt.md}}"
BASE_BRANCH="${CLI_BASE_BRANCH:-${BASE_BRANCH:-main}}"
MAX_RUNTIME="${CLI_MAX_RUNTIME:-${MAX_RUNTIME:-5h}}"
NIGHTLY_BRANCH_PREFIX="${NIGHTLY_BRANCH_PREFIX:-nightly/codex}"
LOG_DIR="${LOG_DIR:-$AI_NIGHTLY_ROOT/logs}"
REPORT_DIR="${REPORT_DIR:-$AI_NIGHTLY_ROOT/reports}"
LOCK_DIR="${LOCK_DIR:-$AI_NIGHTLY_ROOT/run/lock}"
TEST_COMMAND="${TEST_COMMAND:-}"
LINT_COMMAND="${LINT_COMMAND:-}"
BUILD_COMMAND="${BUILD_COMMAND:-}"
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"
CODEX_APPROVAL_POLICY="${CODEX_APPROVAL_POLICY:-never}"
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_PROFILE="${CODEX_PROFILE:-}"
CODEX_EXEC_ARGS="${CODEX_EXEC_ARGS:-}"
CODEX_AUTONOMY_LEVEL="${CODEX_AUTONOMY_LEVEL:-pr-ready}"
PR_MODE="${CLI_PR_MODE:-${PR_MODE:-draft-file}}"
PR_REMOTE="${PR_REMOTE:-origin}"

[[ "$PR_MODE" =~ ^(off|draft-file|gh-draft)$ ]] || die "PR_MODE must be off, draft-file, or gh-draft"

[[ -n "$REPO_PATH" ]] || die "REPO_PATH is required via config or --repo"
[[ -f "$TASK_FILE" ]] || die "task file not found: $TASK_FILE"

require_command git
require_command timeout
if [[ "$SKIP_CODEX" != "true" && "$DRY_RUN" != "true" ]]; then
  require_command "$CODEX_BIN"
fi

DATE_STAMP="$(date '+%Y%m%d')"
JOB_ID="${JOB_ID:-${DATE_STAMP}-$(date '+%H%M%S')-$(sanitize_name "$REPO_NAME")}"
NIGHTLY_BRANCH="${NIGHTLY_BRANCH:-${NIGHTLY_BRANCH_PREFIX}/${JOB_ID}}"
DAY_LOG_DIR="$LOG_DIR/$DATE_STAMP"
DAY_REPORT_DIR="$REPORT_DIR/$DATE_STAMP"
ensure_dir "$DAY_LOG_DIR"
ensure_dir "$DAY_REPORT_DIR"
ensure_dir "$LOCK_DIR"

LOG_FILE="$DAY_LOG_DIR/$JOB_ID.log"
DIFF_FILE="$DAY_LOG_DIR/$JOB_ID.diff"
DIFF_STAT_FILE="$DAY_LOG_DIR/$JOB_ID.diffstat"
STATUS_FILE="$DAY_LOG_DIR/$JOB_ID.status"
META_FILE="$DAY_LOG_DIR/$JOB_ID.meta"
FINAL_MESSAGE_FILE="$DAY_LOG_DIR/$JOB_ID.final.md"
REPORT_FILE="$DAY_REPORT_DIR/$JOB_ID.md"
PR_DRAFT_FILE="$DAY_REPORT_DIR/$JOB_ID-pr.md"
PR_URL_FILE="$DAY_REPORT_DIR/$JOB_ID-pr.url"
LOCK_PATH="$LOCK_DIR/$(sanitize_name "$REPO_NAME").lock"

if [[ "$DRY_RUN" == "true" ]]; then
  "$SCRIPT_DIR/prepare_repo.sh" --repo "$REPO_PATH" --base "$BASE_BRANCH" --branch "$NIGHTLY_BRANCH" --dry-run
  log "dry-run: task file: $TASK_FILE"
  log "dry-run: logs would be written to $DAY_LOG_DIR"
  exit 0
fi

mkdir "$LOCK_PATH" 2>/dev/null || die "lock exists: $LOCK_PATH"
cleanup_lock() {
  # shellcheck disable=SC2317
  "$SCRIPT_DIR/cleanup.sh" --lock "$LOCK_PATH" >/dev/null 2>&1 || true
}
trap cleanup_lock EXIT INT TERM

started_epoch="$(date '+%s')"
started_at="$(date '+%Y-%m-%dT%H:%M:%S%z')"
: >"$LOG_FILE"
: >"$DIFF_FILE"
: >"$DIFF_STAT_FILE"
: >"$STATUS_FILE"
: >"$META_FILE"

write_meta "$META_FILE" job_id "$JOB_ID"
write_meta "$META_FILE" started_at "$started_at"
write_meta "$META_FILE" hostname "$(hostname)"
write_meta "$META_FILE" repo_name "$REPO_NAME"
write_meta "$META_FILE" repo_path "$REPO_PATH"
write_meta "$META_FILE" branch_name "$NIGHTLY_BRANCH"
write_meta "$META_FILE" autonomy_level "$CODEX_AUTONOMY_LEVEL"
write_meta "$META_FILE" pr_mode "$PR_MODE"
write_meta "$META_FILE" task_file "$TASK_FILE"
write_meta "$META_FILE" final_message_file "$FINAL_MESSAGE_FILE"

log "starting job $JOB_ID" | tee -a "$LOG_FILE"
log "autonomy level: $CODEX_AUTONOMY_LEVEL; PR mode: $PR_MODE" >>"$LOG_FILE"

"$SCRIPT_DIR/prepare_repo.sh" --repo "$REPO_PATH" --base "$BASE_BRANCH" --branch "$NIGHTLY_BRANCH" >>"$LOG_FILE" 2>&1

codex_exit_code=0
if [[ "$SKIP_CODEX" == "true" ]]; then
  log "skip-codex enabled; Codex invocation omitted" >>"$LOG_FILE"
else
  log "running Codex with timeout $MAX_RUNTIME" >>"$LOG_FILE"
  CODEX_COMMAND_ARGS=(
    -a "$CODEX_APPROVAL_POLICY"
    --no-alt-screen
    exec
    -C "$REPO_PATH"
    -s "$CODEX_SANDBOX"
    --color never
    --output-last-message "$FINAL_MESSAGE_FILE"
  )
  if [[ -n "$CODEX_MODEL" ]]; then
    CODEX_COMMAND_ARGS+=(-m "$CODEX_MODEL")
  fi
  if [[ -n "$CODEX_PROFILE" ]]; then
    CODEX_COMMAND_ARGS+=(-p "$CODEX_PROFILE")
  fi
  if [[ -n "$CODEX_EXEC_ARGS" ]]; then
    read -r -a CODEX_EXTRA_ARGS_ARRAY <<<"$CODEX_EXEC_ARGS"
    CODEX_COMMAND_ARGS+=("${CODEX_EXTRA_ARGS_ARRAY[@]}")
  fi
  CODEX_COMMAND_ARGS+=(-)
  set +e
  timeout "$MAX_RUNTIME" "$CODEX_BIN" "${CODEX_COMMAND_ARGS[@]}" <"$TASK_FILE" >>"$LOG_FILE" 2>&1
  codex_exit_code=$?
  set -e
fi

run_check() {
  local key="$1"
  local label="$2"
  local command_text="$3"
  local code=0

  if [[ -z "$command_text" ]]; then
    write_meta "$META_FILE" "$key" "not_run"
    return 0
  fi

  set +e
  (
    cd "$REPO_PATH"
    bash -lc "$command_text"
  ) >>"$LOG_FILE" 2>&1
  code=$?
  set -e
  log "$label exit code: $code" >>"$LOG_FILE"
  write_meta "$META_FILE" "$key" "$code"
}

run_check test_exit_code "test" "$TEST_COMMAND"
run_check lint_exit_code "lint" "$LINT_COMMAND"
run_check build_exit_code "build" "$BUILD_COMMAND"

git -C "$REPO_PATH" status --short >"$STATUS_FILE" 2>>"$LOG_FILE" || true
cat "$STATUS_FILE" >>"$LOG_FILE"
git -C "$REPO_PATH" diff --stat >"$DIFF_STAT_FILE" 2>>"$LOG_FILE" || true
git -C "$REPO_PATH" diff >"$DIFF_FILE" 2>>"$LOG_FILE" || true

ended_epoch="$(date '+%s')"
ended_at="$(date '+%Y-%m-%dT%H:%M:%S%z')"
write_meta "$META_FILE" ended_at "$ended_at"
write_meta "$META_FILE" exit_code "$codex_exit_code"
write_meta "$META_FILE" duration_sec "$((ended_epoch - started_epoch))"
write_meta "$META_FILE" log_file "$LOG_FILE"
write_meta "$META_FILE" diff_file "$DIFF_FILE"
write_meta "$META_FILE" diff_stat_file "$DIFF_STAT_FILE"
write_meta "$META_FILE" status_file "$STATUS_FILE"
write_meta "$META_FILE" report_file "$REPORT_FILE"

write_pr_draft() {
  [[ "$PR_MODE" != "off" ]] || return 0
  ensure_dir "$(dirname "$PR_DRAFT_FILE")"
  {
    printf '# PR Draft: Nightly Codex - %s\n\n' "$REPO_NAME"
    printf '## Summary\n\n'
    if [[ -s "$FINAL_MESSAGE_FILE" ]]; then
      sed -n '1,120p' "$FINAL_MESSAGE_FILE"
      printf '\n'
    elif [[ "$SKIP_CODEX" == "true" ]]; then
      printf -- '- Codex execution was skipped for smoke verification.\n'
    else
      printf -- '- Codex did not produce a final-message file. Check the job log first.\n'
    fi
    printf '\n## Verification\n\n'
    printf -- "- Codex exit code: \`%s\`\n" "$codex_exit_code"
    printf -- "- Test: \`%s\`\n" "$(read_meta_value "$META_FILE" test_exit_code || printf 'not_run')"
    printf -- "- Lint: \`%s\`\n" "$(read_meta_value "$META_FILE" lint_exit_code || printf 'not_run')"
    printf -- "- Build: \`%s\`\n" "$(read_meta_value "$META_FILE" build_exit_code || printf 'not_run')"
    printf '\n## Changed Files\n\n'
    if [[ -s "$STATUS_FILE" ]]; then
      printf '```text\n'
      cat "$STATUS_FILE"
      printf '\n```\n'
    else
      printf 'No Git status changes were detected.\n'
    fi
    printf '\n## Diff Stat\n\n'
    if [[ -s "$DIFF_STAT_FILE" ]]; then
      printf '```text\n'
      cat "$DIFF_STAT_FILE"
      printf '\n```\n'
    else
      printf 'No diff stat was generated.\n'
    fi
    printf '\n## Operator Checklist\n\n'
    printf -- '- [ ] Review the diff for unintended file changes.\n'
    printf -- '- [ ] Confirm no secrets, credentials, or production data were added.\n'
    printf -- '- [ ] Re-run the project verification commands if needed.\n'
    printf -- "- [ ] Push \`%s\` and open this PR only after human review.\n" "$NIGHTLY_BRANCH"
    printf '\n## References\n\n'
    printf -- "- Branch: \`%s\`\n" "$NIGHTLY_BRANCH"
    printf -- "- Report: \`%s\`\n" "$REPORT_FILE"
    printf -- "- Log: \`%s\`\n" "$LOG_FILE"
  } >"$PR_DRAFT_FILE"
  write_meta "$META_FILE" pr_draft_file "$PR_DRAFT_FILE"
}

publish_draft_pr() {
  [[ "$PR_MODE" == "gh-draft" ]] || return 0
  require_command gh
  git -C "$REPO_PATH" push -u "$PR_REMOTE" "$NIGHTLY_BRANCH" >>"$LOG_FILE" 2>&1
  (
    cd "$REPO_PATH"
    gh pr create \
      --draft \
      --base "$BASE_BRANCH" \
      --head "$NIGHTLY_BRANCH" \
      --title "Nightly Codex: ${REPO_NAME}" \
      --body-file "$PR_DRAFT_FILE"
  ) >"$PR_URL_FILE" 2>>"$LOG_FILE"
  write_meta "$META_FILE" pr_url_file "$PR_URL_FILE"
}

write_pr_draft
publish_draft_pr

"$SCRIPT_DIR/summarize_result.sh" \
  --meta "$META_FILE" \
  --report "$REPORT_FILE" \
  --log "$LOG_FILE" \
  --diff-stat "$DIFF_STAT_FILE" \
  --status "$STATUS_FILE" \
  --task "$TASK_FILE"

log "finished job $JOB_ID with Codex exit code $codex_exit_code" | tee -a "$LOG_FILE"
exit "$codex_exit_code"
