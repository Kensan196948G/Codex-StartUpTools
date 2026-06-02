#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: auto_setup.sh [options]

Creates config/env files, infers verification commands, validates the job, and
optionally installs a schedule without interactive prompts.

Options:
  --repo PATH          Target Git repository. Defaults to TARGET_REPO, REPO_PATH, or current Git repo.
  --repo-name NAME     Logical repository name. Defaults to basename of --repo.
  --base BRANCH        Base branch. Defaults to origin HEAD, current branch, main, or master.
  --task FILE          Task Markdown file. Defaults to tasks/codex_goal_prompt.md.
  --config FILE        Output config file. Defaults to config/jobs.conf.
  --env FILE           Output env file. Defaults to config/env.sh.
  --schedule MODE      none, cron, or systemd-user. Default: cron.
  --days DOW           Cron day-of-week field. Default: * (0=Sun, 1=Mon, ..., 6=Sat).
  --time HH:MM         Scheduled start time. Default: 00:00.
  --max-runtime DUR    timeout duration. Default: 5h.
  --pr-mode MODE       off, draft-file, or gh-draft. Default: draft-file.
  --test CMD           Override inferred test command.
  --lint CMD           Override inferred lint command.
  --build CMD          Override inferred build command.
  --smoke-run          Run --skip-codex after dry-run.
  --run-now            Run Codex immediately after setup.
  --force              Overwrite existing config/env files.
  --no-verify          Skip make verify.
  -h, --help           Show this help.
USAGE
}

shell_quote() {
  printf '%q' "$1"
}

detect_repo() {
  if [[ -n "${TARGET_REPO:-}" ]]; then
    printf '%s\n' "$TARGET_REPO"
  elif [[ -n "${REPO_PATH:-}" ]]; then
    printf '%s\n' "$REPO_PATH"
  elif git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$PWD" rev-parse --show-toplevel
  else
    return 1
  fi
}

detect_base_branch() {
  local repo="$1"
  local branch=""

  branch="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  if [[ -n "$branch" ]]; then
    printf '%s\n' "$branch"
    return 0
  fi

  branch="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
  if [[ -n "$branch" ]]; then
    printf '%s\n' "$branch"
    return 0
  fi

  if git -C "$repo" show-ref --verify --quiet refs/heads/main; then
    printf 'main\n'
  elif git -C "$repo" show-ref --verify --quiet refs/heads/master; then
    printf 'master\n'
  else
    printf 'main\n'
  fi
}

has_make_target() {
  local repo="$1"
  local target="$2"
  [[ -f "$repo/Makefile" ]] && grep -Eq "^${target}:" "$repo/Makefile"
}

package_has_script() {
  local repo="$1"
  local script="$2"
  [[ -f "$repo/package.json" ]] && grep -Eq "\"${script}\"[[:space:]]*:" "$repo/package.json"
}

infer_test_command() {
  local repo="$1"
  if has_make_target "$repo" test; then
    printf 'make test\n'
  elif package_has_script "$repo" test; then
    printf 'npm test\n'
  elif [[ -f "$repo/pyproject.toml" || -f "$repo/pytest.ini" || -d "$repo/tests" ]]; then
    printf 'pytest\n'
  else
    printf '\n'
  fi
}

infer_lint_command() {
  local repo="$1"
  if has_make_target "$repo" lint; then
    printf 'make lint\n'
  elif package_has_script "$repo" lint; then
    printf 'npm run lint\n'
  elif [[ -f "$repo/pyproject.toml" ]] && grep -Eq 'ruff|flake8' "$repo/pyproject.toml"; then
    printf 'ruff check .\n'
  else
    printf '\n'
  fi
}

infer_build_command() {
  local repo="$1"
  if has_make_target "$repo" build; then
    printf 'make build\n'
  elif package_has_script "$repo" build; then
    printf 'npm run build\n'
  else
    printf '\n'
  fi
}

write_config() {
  local file="$1"
  ensure_dir "$(dirname "$file")"
  if [[ -f "$file" && "$FORCE" != "true" ]]; then
    die "config already exists: $file; pass --force to overwrite"
  fi

  {
    printf 'REPO_NAME=%q\n' "$REPO_NAME"
    printf 'REPO_PATH=%q\n' "$REPO_PATH"
    printf 'BASE_BRANCH=%q\n' "$BASE_BRANCH"
    printf 'NIGHTLY_BRANCH_PREFIX=%q\n' "$NIGHTLY_BRANCH_PREFIX"
    printf 'TASK_FILE=%q\n' "$TASK_FILE"
    printf 'MAX_RUNTIME=%q\n' "$MAX_RUNTIME"
    printf 'LOG_DIR=%q\n' "$LOG_DIR"
    printf 'REPORT_DIR=%q\n' "$REPORT_DIR"
    printf 'LOCK_DIR=%q\n' "$LOCK_DIR"
    printf 'TEST_COMMAND=%q\n' "$TEST_COMMAND"
    printf 'LINT_COMMAND=%q\n' "$LINT_COMMAND"
    printf 'BUILD_COMMAND=%q\n' "$BUILD_COMMAND"
    printf 'CODEX_BIN=%q\n' "$CODEX_BIN"
    printf 'CODEX_SANDBOX=%q\n' "$CODEX_SANDBOX"
    printf 'CODEX_APPROVAL_POLICY=%q\n' "$CODEX_APPROVAL_POLICY"
    printf 'CODEX_MODEL=%q\n' "$CODEX_MODEL"
    printf 'CODEX_PROFILE=%q\n' "$CODEX_PROFILE"
    printf 'CODEX_EXEC_ARGS=%q\n' "$CODEX_EXEC_ARGS"
    printf 'CODEX_AUTONOMY_LEVEL=%q\n' "$CODEX_AUTONOMY_LEVEL"
    printf 'PR_MODE=%q\n' "$PR_MODE"
    printf 'PR_REMOTE=%q\n' "$PR_REMOTE"
  } >"$file"
}

write_env() {
  local file="$1"
  ensure_dir "$(dirname "$file")"
  if [[ -f "$file" && "$FORCE" != "true" ]]; then
    die "env file already exists: $file; pass --force to overwrite"
  fi

  {
    printf "%s\n" "export OPENAI_API_KEY=\"\${OPENAI_API_KEY:-}\""
    printf 'export PATH=%q\n' "$PATH"
    printf 'export LANG=%q\n' "${LANG:-C.UTF-8}"
    printf 'export TZ=%q\n' "${TZ:-Asia/Tokyo}"
  } >"$file"
  chmod 600 "$file"
}

install_cron() {
  require_command crontab
  local hour="${SCHEDULE_TIME%:*}"
  local minute="${SCHEDULE_TIME#*:}"
  local marker
  local line
  marker="# ai-nightly:$(sanitize_name "$REPO_NAME")"
  line="${minute} ${hour} * * ${SCHEDULE_DAYS} cd $(shell_quote "$AI_NIGHTLY_ROOT") && . $(shell_quote "$ENV_FILE") && $(shell_quote "$SCRIPT_DIR/nightly_codex.sh") --config $(shell_quote "$CONFIG_FILE") >> $(shell_quote "$LOG_DIR/cron.log") 2>&1 ${marker}"

  {
    crontab -l 2>/dev/null | grep -Fv "$marker" || true
    printf '%s\n' "$line"
  } | crontab -
  log "installed cron schedule: days=$SCHEDULE_DAYS time=$SCHEDULE_TIME ($marker)"
}

install_systemd_user() {
  require_command systemctl
  local unit_dir="$HOME/.config/systemd/user"
  local unit_name
  local service_file
  local timer_file

  ensure_dir "$unit_dir"
  unit_name="ai-nightly-$(sanitize_name "$REPO_NAME")"
  service_file="$unit_dir/${unit_name}.service"
  timer_file="$unit_dir/${unit_name}.timer"
  cat >"$service_file" <<SERVICE
[Unit]
Description=AI Nightly Codex job for ${REPO_NAME}

[Service]
Type=oneshot
WorkingDirectory=${AI_NIGHTLY_ROOT}
ExecStart=/bin/bash -lc '. ${ENV_FILE} && ${SCRIPT_DIR}/nightly_codex.sh --config ${CONFIG_FILE}'
SERVICE

  cat >"$timer_file" <<TIMER
[Unit]
Description=Run ${unit_name}.service every day

[Timer]
OnCalendar=*-*-* ${SCHEDULE_TIME}:00
Persistent=true
Unit=${unit_name}.service

[Install]
WantedBy=timers.target
TIMER

  systemctl --user daemon-reload
  systemctl --user enable --now "${unit_name}.timer"
  log "installed systemd user timer: ${unit_name}.timer"
}

REPO_PATH=""
REPO_NAME=""
BASE_BRANCH=""
TASK_FILE="$AI_NIGHTLY_ROOT/tasks/codex_goal_prompt.md"
CONFIG_FILE="$AI_NIGHTLY_ROOT/config/jobs.conf"
ENV_FILE="$AI_NIGHTLY_ROOT/config/env.sh"
SCHEDULE_MODE="cron"
SCHEDULE_DAYS="*"
SCHEDULE_TIME="00:00"
MAX_RUNTIME="5h"
NIGHTLY_BRANCH_PREFIX="nightly/codex"
LOG_DIR="$AI_NIGHTLY_ROOT/logs"
REPORT_DIR="$AI_NIGHTLY_ROOT/reports"
LOCK_DIR="$AI_NIGHTLY_ROOT/run/lock"
TEST_COMMAND=""
LINT_COMMAND=""
BUILD_COMMAND=""
CODEX_BIN="codex"
CODEX_SANDBOX="workspace-write"
CODEX_APPROVAL_POLICY="never"
CODEX_MODEL=""
CODEX_PROFILE=""
CODEX_EXEC_ARGS=""
CODEX_AUTONOMY_LEVEL="pr-ready"
PR_MODE="draft-file"
PR_REMOTE="origin"
SMOKE_RUN="false"
RUN_NOW="false"
FORCE="false"
VERIFY="true"
TEST_OVERRIDE="false"
LINT_OVERRIDE="false"
BUILD_OVERRIDE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_PATH="$2"; shift 2 ;;
    --repo-name) REPO_NAME="$2"; shift 2 ;;
    --base) BASE_BRANCH="$2"; shift 2 ;;
    --task) TASK_FILE="$2"; shift 2 ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --env) ENV_FILE="$2"; shift 2 ;;
    --schedule) SCHEDULE_MODE="$2"; shift 2 ;;
    --days) SCHEDULE_DAYS="$2"; shift 2 ;;
    --time) SCHEDULE_TIME="$2"; shift 2 ;;
    --max-runtime) MAX_RUNTIME="$2"; shift 2 ;;
    --pr-mode) PR_MODE="$2"; shift 2 ;;
    --test) TEST_COMMAND="$2"; TEST_OVERRIDE="true"; shift 2 ;;
    --lint) LINT_COMMAND="$2"; LINT_OVERRIDE="true"; shift 2 ;;
    --build) BUILD_COMMAND="$2"; BUILD_OVERRIDE="true"; shift 2 ;;
    --smoke-run) SMOKE_RUN="true"; shift ;;
    --run-now) RUN_NOW="true"; shift ;;
    --force) FORCE="true"; shift ;;
    --no-verify) VERIFY="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$SCHEDULE_MODE" =~ ^(none|cron|systemd-user)$ ]] || die "--schedule must be none, cron, or systemd-user"
[[ "$SCHEDULE_DAYS" =~ ^(\*|[0-7](-[0-7])?(,[0-7](-[0-7])?)*)$ ]] || die "--days must be cron day-of-week format, e.g. *, 1-5, 0,6"
[[ "$SCHEDULE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--time must be HH:MM"
[[ "$PR_MODE" =~ ^(off|draft-file|gh-draft)$ ]] || die "--pr-mode must be off, draft-file, or gh-draft"
if [[ "$MAX_RUNTIME" =~ ^([1-9][0-9]*)([hm])$ ]]; then
  if { [[ "${BASH_REMATCH[2]}" == "h" ]] && (( BASH_REMATCH[1] > 5 )); } || { [[ "${BASH_REMATCH[2]}" == "m" ]] && (( BASH_REMATCH[1] > 300 )); }; then
    die "--max-runtime must be 5h or 300m at most"
  fi
else
  die "--max-runtime must be a positive duration using h or m, e.g. 2h, 90m, 5h"
fi

if [[ -z "$REPO_PATH" ]]; then
  REPO_PATH="$(detect_repo)" || die "target repository not found; pass --repo PATH"
fi
[[ -d "$REPO_PATH" ]] || die "repository path not found: $REPO_PATH"
REPO_PATH="$(cd "$REPO_PATH" && pwd)"
git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git repository: $REPO_PATH"

[[ -n "$REPO_NAME" ]] || REPO_NAME="$(basename "$REPO_PATH")"
[[ -n "$BASE_BRANCH" ]] || BASE_BRANCH="$(detect_base_branch "$REPO_PATH")"
[[ -f "$TASK_FILE" ]] || die "task file not found: $TASK_FILE"
TASK_FILE="$(cd "$(dirname "$TASK_FILE")" && pwd)/$(basename "$TASK_FILE")"

if [[ "$TEST_OVERRIDE" != "true" ]]; then
  TEST_COMMAND="$(infer_test_command "$REPO_PATH")"
fi
if [[ "$LINT_OVERRIDE" != "true" ]]; then
  LINT_COMMAND="$(infer_lint_command "$REPO_PATH")"
fi
if [[ "$BUILD_OVERRIDE" != "true" ]]; then
  BUILD_COMMAND="$(infer_build_command "$REPO_PATH")"
fi

write_config "$CONFIG_FILE"
write_env "$ENV_FILE"
chmod +x "$SCRIPT_DIR"/*.sh "$AI_NIGHTLY_ROOT/tests/run_tests.sh" 2>/dev/null || true

if [[ "$VERIFY" == "true" ]]; then
  make -C "$AI_NIGHTLY_ROOT" verify
fi

"$SCRIPT_DIR/nightly_codex.sh" --config "$CONFIG_FILE" --dry-run

case "$SCHEDULE_MODE" in
  none) log "schedule installation skipped" ;;
  cron) install_cron ;;
  systemd-user) install_systemd_user ;;
esac

if [[ "$SMOKE_RUN" == "true" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  "$SCRIPT_DIR/nightly_codex.sh" --config "$CONFIG_FILE" --skip-codex
fi

if [[ "$RUN_NOW" == "true" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  "$SCRIPT_DIR/nightly_codex.sh" --config "$CONFIG_FILE"
fi

log "auto setup completed for $REPO_NAME"
