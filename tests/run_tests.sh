#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -q "$pattern" "$file" || fail "expected $file to contain: $pattern"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  ! grep -q "$pattern" "$file" || fail "expected $file not to contain: $pattern"
}

write_fake_crontab() {
  local file="$1"
  cat >"$file" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

crontab_file="${TEST_CRONTAB_FILE:?}"

if [[ "${1:-}" == "-l" ]]; then
  if [[ -f "$crontab_file" ]]; then
    cat "$crontab_file"
  else
    exit 1
  fi
elif [[ "$#" -eq 0 || "${1:-}" == "-" ]]; then
  cat >"$crontab_file"
else
  exit 2
fi
SH
  chmod +x "$file"
}

test_dry_run() {
  local repo="$TMP_DIR/repo-dry"
  mkdir -p "$repo"
  git -C "$repo" init -b main >/dev/null
  printf '# dry\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m init >/dev/null

  "$ROOT/bin/nightly_codex.sh" \
    --repo "$repo" \
    --repo-name repo-dry \
    --task "$ROOT/tasks/default_task.md" \
    --dry-run >/dev/null

  current_branch="$(git -C "$repo" branch --show-current)"
  [[ "$current_branch" == "main" ]] || fail "dry-run changed branch"
  pass "dry-run validates without modifying repository"
}

test_skip_codex_report() {
  local repo="$TMP_DIR/repo-run"
  local out="$TMP_DIR/out"
  mkdir -p "$repo" "$out"
  git -C "$repo" init -b main >/dev/null
  printf '# run\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m init >/dev/null

  cat >"$TMP_DIR/jobs.conf" <<CONF
REPO_NAME="org/repo-run"
REPO_PATH="$repo"
BASE_BRANCH="main"
TASK_FILE="$ROOT/tasks/default_task.md"
LOG_DIR="$out/logs"
REPORT_DIR="$out/reports"
LOCK_DIR="$out/run/lock"
TEST_COMMAND="test -f README.md"
LINT_COMMAND=":"
BUILD_COMMAND=":"
CONF

  "$ROOT/bin/nightly_codex.sh" --config "$TMP_DIR/jobs.conf" --skip-codex >/dev/null

  report="$(find "$out/reports" -type f -name '*.md' ! -name '*-pr.md' | head -n 1)"
  pr_draft="$(find "$out/reports" -type f -name '*-pr.md' | head -n 1)"
  meta="$(find "$out/logs" -type f -name '*.meta' | head -n 1)"
  assert_file "$report"
  assert_file "$pr_draft"
  assert_file "$meta"
  assert_contains "$report" "Nightly Codex Report"
  assert_contains "$report" "PR draft"
  assert_contains "$pr_draft" "PR Draft: Nightly Codex"
  assert_contains "$pr_draft" "Operator Checklist"
  assert_contains "$report" "Test: \`0\`"
  assert_contains "$meta" "exit_code=0"
  assert_contains "$meta" "autonomy_level=pr-ready"
  assert_contains "$meta" "pr_mode=draft-file"
  [[ ! -d "$out/run/lock/org" ]] || fail "lock path should not create nested repo-name directories"
  pass "skip-codex run creates report and metadata"
}

test_prepare_rejects_non_git() {
  local repo="$TMP_DIR/not-git"
  mkdir -p "$repo"
  if "$ROOT/bin/prepare_repo.sh" --repo "$repo" --base main --branch nightly/test >/dev/null 2>&1; then
    fail "prepare_repo accepted non-git directory"
  fi
  pass "prepare_repo rejects non-git directory"
}

test_auto_setup_generates_config() {
  local repo="$TMP_DIR/repo-auto"
  local out="$TMP_DIR/auto-out"
  mkdir -p "$repo" "$out"
  git -C "$repo" init -b main >/dev/null
  printf '{"scripts":{"test":"echo test","lint":"echo lint","build":"echo build"}}\n' >"$repo/package.json"
  git -C "$repo" add package.json
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m init >/dev/null

  "$ROOT/bin/auto_setup.sh" \
    --repo "$repo" \
    --repo-name repo-auto \
    --config "$out/jobs.conf" \
    --env "$out/env.sh" \
    --schedule none \
    --no-verify \
    --force >/dev/null

  assert_file "$out/jobs.conf"
  assert_file "$out/env.sh"
  assert_contains "$out/jobs.conf" "REPO_NAME=repo-auto"
  assert_contains "$out/jobs.conf" "TEST_COMMAND=npm\\\\\\ test"
  assert_contains "$out/jobs.conf" "LINT_COMMAND=npm\\\\\\ run\\\\\\ lint"
  assert_contains "$out/jobs.conf" "BUILD_COMMAND=npm\\\\\\ run\\\\\\ build"
  assert_contains "$out/jobs.conf" "CODEX_AUTONOMY_LEVEL=pr-ready"
  assert_contains "$out/jobs.conf" "PR_MODE=draft-file"
  pass "auto_setup generates config and infers npm commands"
}

test_auto_setup_installs_cron_with_days_time_runtime() {
  local repo="$TMP_DIR/repo-cron"
  local out="$TMP_DIR/cron-out"
  local fakebin="$out/fakebin"
  mkdir -p "$repo" "$out" "$fakebin"
  git -C "$repo" init -b main >/dev/null
  printf '# cron\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m init >/dev/null
  write_fake_crontab "$fakebin/crontab"

  TEST_CRONTAB_FILE="$out/crontab" PATH="$fakebin:$PATH" "$ROOT/bin/auto_setup.sh" \
    --repo "$repo" \
    --repo-name repo-cron \
    --config "$out/jobs.conf" \
    --env "$out/env.sh" \
    --schedule cron \
    --days 1-5 \
    --time 02:30 \
    --max-runtime 2h \
    --no-verify \
    --force >"$out/setup.txt"

  assert_contains "$out/jobs.conf" "MAX_RUNTIME=2h"
  assert_contains "$out/crontab" "30 02 \\* \\* 1-5"
  assert_contains "$out/setup.txt" "days=1-5 time=02:30"
  pass "auto_setup installs cron with weekday, time, and runtime"
}

test_codex_startup_dry_run_records_recent() {
  local repo="$TMP_DIR/repo-startup"
  local out="$TMP_DIR/startup-out"
  mkdir -p "$repo" "$out"
  git -C "$repo" init -b main >/dev/null
  printf '# startup\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m init >/dev/null

  cat >"$out/startup.conf" <<CONF
PROJECTS_DIR="$TMP_DIR"
CODEX_COMMAND="true"
STARTUP_LOG_DIR="$out/logs"
RECENT_PROJECTS_FILE="$out/recent.tsv"
MENU_MAX_PROJECTS="20"
CONF

  STARTUP_CONFIG_FILE="$out/startup.conf" "$ROOT/bin/codex_startup.sh" \
    --project "$repo" \
    --dry-run >"$out/launch.txt"

  assert_contains "$out/launch.txt" "Codex Launch Plan"
  assert_contains "$out/recent.tsv" "repo-startup"
  assert_contains "$out/recent.tsv" "dry-run"
  pass "codex_startup dry-run records recent project"
}

test_codex_menu_once_list_projects() {
  local repo="$TMP_DIR/repo-menu"
  local out="$TMP_DIR/menu-out"
  mkdir -p "$repo" "$out"
  cat >"$out/startup.conf" <<CONF
PROJECTS_DIR="$TMP_DIR"
CODEX_COMMAND="true"
STARTUP_LOG_DIR="$out/logs"
RECENT_PROJECTS_FILE="$out/recent.tsv"
MENU_MAX_PROJECTS="20"
CONF

  STARTUP_CONFIG_FILE="$out/startup.conf" "$ROOT/bin/codex_menu.sh" --once list-projects >"$out/projects.txt"
  assert_contains "$out/projects.txt" "repo-menu"
  pass "codex_menu one-shot project listing works"
}

test_select_project_interactive_returns_path_only() {
  local projects="$TMP_DIR/select-projects"
  local repo="$projects/repo-select"
  local out="$TMP_DIR/select-out"
  mkdir -p "$repo" "$out"

  cat >"$out/startup.conf" <<CONF
PROJECTS_DIR="$projects"
CODEX_COMMAND="true"
STARTUP_LOG_DIR="$out/logs"
RECENT_PROJECTS_FILE="$out/recent.tsv"
MENU_MAX_PROJECTS="20"
CONF

  STARTUP_CONFIG_FILE="$out/startup.conf" bash -c "
    set -euo pipefail
    source '$ROOT/lib/common.sh'
    source '$ROOT/lib/startup.sh'
    load_startup_config
    select_project_interactive
  " >"$out/stdout.txt" 2>"$out/stderr.txt" <<<"1"

  [[ "$(cat "$out/stdout.txt")" == "$repo" ]] || fail "interactive selection stdout should contain only the selected path"
  assert_contains "$out/stderr.txt" "プロジェクト一覧"
  pass "select_project_interactive keeps UI output separate from returned path"
}

test_codex_menu_interactive_recovers_from_failed_action() {
  local projects="$TMP_DIR/recover-projects"
  local non_git="$projects/not-git"
  local out="$TMP_DIR/recover-out"
  local status
  mkdir -p "$non_git" "$out"

  cat >"$out/startup.conf" <<CONF
PROJECTS_DIR="$projects"
CODEX_COMMAND="true"
STARTUP_LOG_DIR="$out/logs"
RECENT_PROJECTS_FILE="$out/recent.tsv"
MENU_MAX_PROJECTS="20"
CONF

  set +e
  STARTUP_CONFIG_FILE="$out/startup.conf" "$ROOT/bin/codex_menu.sh" >"$out/stdout.txt" 2>"$out/stderr.txt" <<EOF
5
$non_git
*
00:00
5h

0
EOF
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "interactive menu should recover from failed actions"
  assert_contains "$out/stdout.txt" "コマンドが失敗しました"
  assert_contains "$out/stdout.txt" "終了します"
  assert_contains "$out/stderr.txt" "not a Git repository"
  pass "codex_menu interactive mode recovers from failed actions"
}

test_codex_menu_interactive_runs_common_actions() {
  local projects="$TMP_DIR/menu-projects"
  local repo="$projects/repo-actions"
  local out="$TMP_DIR/menu-actions-out"
  mkdir -p "$repo" "$out"
  git -C "$repo" init -b main >/dev/null
  printf '# menu actions\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m init >/dev/null

  cat >"$out/jobs.conf" <<CONF
REPO_NAME="repo-actions"
REPO_PATH="$repo"
BASE_BRANCH="main"
TASK_FILE="$ROOT/tasks/default_task.md"
LOG_DIR="$out/logs"
REPORT_DIR="$out/reports"
LOCK_DIR="$out/run/lock"
TEST_COMMAND="test -f README.md"
CONF

  cat >"$out/startup.conf" <<CONF
PROJECTS_DIR="$projects"
CODEX_COMMAND="true"
STARTUP_LOG_DIR="$out/startup-logs"
RECENT_PROJECTS_FILE="$out/recent.tsv"
MENU_MAX_PROJECTS="20"
NIGHTLY_CONFIG_FILE="$out/jobs.conf"
NIGHTLY_ENV_FILE="$out/env.sh"
CONF

  STARTUP_CONFIG_FILE="$out/startup.conf" "$ROOT/bin/codex_menu.sh" >"$out/stdout.txt" 2>"$out/stderr.txt" <<EOF
1

2

4
1

6

8

9
0
0
EOF

  assert_contains "$out/stdout.txt" "Codex StartUp ダッシュボード"
  assert_contains "$out/stdout.txt" "repo-actions"
  assert_contains "$out/stdout.txt" "Codex Launch Plan"
  assert_contains "$out/stdout.txt" "dry-run: repository is valid"
  assert_contains "$out/stdout.txt" "dry-run"
  assert_contains "$out/stdout.txt" "管理対象 cron"
  assert_contains "$out/stdout.txt" "終了します"
  assert_contains "$out/stderr.txt" "プロジェクト一覧"
  pass "codex_menu interactive mode runs common actions"
}

test_codex_menu_interactive_auto_setup_prompts_schedule() {
  local projects="$TMP_DIR/menu-setup-projects"
  local repo="$projects/repo-setup"
  local out="$TMP_DIR/menu-setup-out"
  local fakebin="$out/fakebin"
  mkdir -p "$repo" "$out" "$fakebin"
  git -C "$repo" init -b main >/dev/null
  printf '# menu setup\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m init >/dev/null
  write_fake_crontab "$fakebin/crontab"

  cat >"$out/startup.conf" <<CONF
PROJECTS_DIR="$projects"
CODEX_COMMAND="true"
STARTUP_LOG_DIR="$out/startup-logs"
RECENT_PROJECTS_FILE="$out/recent.tsv"
MENU_MAX_PROJECTS="20"
NIGHTLY_CONFIG_FILE="$out/jobs.conf"
NIGHTLY_ENV_FILE="$out/env.sh"
DEFAULT_SCHEDULE="00:00"
DEFAULT_SCHEDULE_DAYS="*"
AUTO_SETUP_VERIFY="false"
CONF

  TEST_CRONTAB_FILE="$out/crontab" PATH="$fakebin:$PATH" STARTUP_CONFIG_FILE="$out/startup.conf" "$ROOT/bin/codex_menu.sh" >"$out/stdout.txt" 2>"$out/stderr.txt" <<EOF
5
1
1-5
02:30
2h

0
EOF

  assert_contains "$out/stdout.txt" "登録内容"
  assert_contains "$out/stdout.txt" "Cron days   : 1-5"
  assert_contains "$out/stdout.txt" "Cron time   : 02:30"
  assert_contains "$out/stdout.txt" "Max runtime : 2h"
  assert_contains "$out/stdout.txt" "登録後確認"
  assert_contains "$out/stdout.txt" "📦 repo-setup"
  assert_contains "$out/stdout.txt" "曜日 : 月-金 (1-5)"
  assert_contains "$out/stdout.txt" "dry-run: repository is valid"
  assert_contains "$out/crontab" "30 02 \\* \\* 1-5"
  assert_contains "$out/stderr.txt" "曜日選択"
  assert_contains "$out/stderr.txt" "0=日 1=月 2=火"
  assert_contains "$out/stderr.txt" "曜日 (例: 0 または 1,3,5)"
  assert_contains "$out/stderr.txt" "最大実行時間"
  pass "codex_menu auto setup prompts for weekday, time, runtime, and confirms registration"
}

test_codex_menu_interactive_manages_cron_entries() {
  local out="$TMP_DIR/menu-cron-manage-out"
  local fakebin="$out/fakebin"
  mkdir -p "$out" "$fakebin"
  write_fake_crontab "$fakebin/crontab"

  cat >"$out/jobs-one.conf" <<CONF
REPO_NAME=repo-one
REPO_PATH=$TMP_DIR/repo-one
BASE_BRANCH=main
TASK_FILE=$ROOT/tasks/default_task.md
MAX_RUNTIME=5h
CONF
  cat >"$out/jobs-two.conf" <<CONF
REPO_NAME=repo-two
REPO_PATH=$TMP_DIR/repo-two
BASE_BRANCH=main
TASK_FILE=$ROOT/tasks/default_task.md
MAX_RUNTIME=5h
CONF
  cat >"$out/startup.conf" <<CONF
PROJECTS_DIR="$TMP_DIR"
CODEX_COMMAND="true"
STARTUP_LOG_DIR="$out/startup-logs"
RECENT_PROJECTS_FILE="$out/recent.tsv"
MENU_MAX_PROJECTS="20"
CONF
  cat >"$out/crontab" <<CONF
10 00 * * * /bin/true # keep-me
15 01 * * 1 cd $ROOT && . $out/env.sh && $ROOT/bin/nightly_codex.sh --config $out/jobs-one.conf >> $out/cron.log 2>&1 # ai-nightly:repo-one
45 03 * * 6 cd $ROOT && . $out/env.sh && $ROOT/bin/nightly_codex.sh --config $out/jobs-two.conf >> $out/cron.log 2>&1 # ai-nightly:repo-two
CONF

  TEST_CRONTAB_FILE="$out/crontab" PATH="$fakebin:$PATH" STARTUP_CONFIG_FILE="$out/startup.conf" "$ROOT/bin/codex_menu.sh" >"$out/stdout.txt" 2>"$out/stderr.txt" <<EOF
9
1
1
0,6
04:20
90m
2
2
y
3
DELETE
0
0
EOF

  assert_contains "$out/stdout.txt" "設定変更"
  assert_contains "$out/stdout.txt" "cron 設定を更新しました"
  assert_contains "$out/stdout.txt" "cron 設定を削除しました"
  assert_contains "$out/stdout.txt" "管理対象 cron を全削除しました"
  assert_contains "$out/jobs-one.conf" "MAX_RUNTIME=90m"
  assert_contains "$out/crontab" "keep-me"
  assert_not_contains "$out/crontab" "ai-nightly:"
  assert_contains "$out/stderr.txt" "対象番号"
  pass "codex_menu interactive cron management changes, deletes, and clears entries"
}

test_codex_menu_tty_colors_are_high_contrast() {
  local out="$TMP_DIR/menu-color-out"
  local repo="$TMP_DIR/repo-color"
  mkdir -p "$out"
  mkdir -p "$repo"

  cat >"$out/startup.conf" <<CONF
PROJECTS_DIR="$TMP_DIR"
CODEX_COMMAND="true"
STARTUP_LOG_DIR="$out/startup-logs"
RECENT_PROJECTS_FILE="$out/recent.tsv"
MENU_MAX_PROJECTS="20"
CONF

  env -u NO_COLOR FORCE_COLOR=1 STARTUP_CONFIG_FILE="$out/startup.conf" bash -c "
    set -euo pipefail
    source '$ROOT/lib/common.sh'
    source '$ROOT/lib/startup.sh'
    load_startup_config
    select_project_interactive
  " >"$out/stdout.txt" 2>"$out/stderr.txt" <<<"1"

  assert_contains "$out/stderr.txt" "\\[1;36m"
  assert_contains "$out/stderr.txt" "\\[1;33m"
  assert_contains "$out/stderr.txt" "\\[1;37m"
  if grep -q "\\[2m" "$out/stderr.txt"; then
    fail "menu output should not use ANSI dim colors"
  fi
  pass "codex_menu TTY colors avoid faint dim styling"
}

test_run_nightly_background_skip_codex() {
  local repo="$TMP_DIR/repo-bg"
  local out="$TMP_DIR/bg-out"
  mkdir -p "$repo" "$out"
  git -C "$repo" init -b main >/dev/null
  printf '# bg\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m init >/dev/null

  cat >"$out/jobs.conf" <<CONF
REPO_NAME="repo-bg"
REPO_PATH="$repo"
BASE_BRANCH="main"
TASK_FILE="$ROOT/tasks/default_task.md"
LOG_DIR="$out/logs"
REPORT_DIR="$out/reports"
LOCK_DIR="$out/run/lock"
TEST_COMMAND="test -f README.md"
CONF

  cat >"$out/startup.conf" <<CONF
PROJECTS_DIR="$TMP_DIR"
CODEX_COMMAND="true"
STARTUP_LOG_DIR="$out/startup-logs"
RECENT_PROJECTS_FILE="$out/recent.tsv"
MENU_MAX_PROJECTS="20"
CONF

  STARTUP_CONFIG_FILE="$out/startup.conf" bash -c "
    set -euo pipefail
    source '$ROOT/lib/common.sh'
    source '$ROOT/lib/startup.sh'
    load_startup_config
    run_nightly_background '$out/jobs.conf' '$out/env.sh' '--skip-codex' >'$out/bg.txt'
  "

  assert_contains "$out/bg.txt" "PID"
  pid_file="$ROOT/run/nightly-background.pid"
  assert_file "$pid_file"
  pid="$(cat "$pid_file")"
  for _ in 1 2 3 4 5; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  [[ -n "$(find "$ROOT/logs/background" -type f -name 'nightly-background-*.log' | tail -n 1)" ]] || fail "background log not found"
  pass "run_nightly_background starts detached nightly job"
}

test_dry_run
test_skip_codex_report
test_prepare_rejects_non_git
test_auto_setup_generates_config
test_auto_setup_installs_cron_with_days_time_runtime
test_codex_startup_dry_run_records_recent
test_codex_menu_once_list_projects
test_select_project_interactive_returns_path_only
test_codex_menu_interactive_recovers_from_failed_action
test_codex_menu_interactive_runs_common_actions
test_codex_menu_interactive_auto_setup_prompts_schedule
test_codex_menu_interactive_manages_cron_entries
test_codex_menu_tty_colors_are_high_contrast
test_run_nightly_background_skip_codex
