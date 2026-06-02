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
Usage: codex_menu.sh [--once ACTION]

Interactive Linux Codex startup management menu.

Actions for --once:
  dashboard, list-projects, recent, verify, cron-list, run-nightly-bg, help
USAGE
}

wait_enter() {
  printf '\n%s\n' "$(color "$C_CYAN" "↩️  [Enter] でメニューに戻ります...")"
  read -r _
}

prompt_schedule_time() {
  local value

  while true; do
    printf '%s ' "$(color "$C_BOLD$C_GREEN" "🕛 cron 実行時刻を入力してください [${DEFAULT_SCHEDULE}]:")" >&2
    read -r value
    value="${value:-$DEFAULT_SCHEDULE}"
    if [[ "$value" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    printf '%s\n' "$(color "$C_RED" "❌ 時刻は HH:MM 形式で入力してください。例: 00:00, 03:30")" >&2
  done
}

prompt_schedule_days() {
  local value

  while true; do
    printf '%s\n' "$(color "$C_BOLD$C_CYAN" "-- 曜日選択 (複数可、カンマ区切り) --")" >&2
    printf '    %s\n' "$(color "$C_WHITE" "0=日 1=月 2=火 3=水 4=木 5=金 6=土")" >&2
    printf '    %s\n' "$(color "$C_CYAN" "補足: *=毎日, 1-5=月-金, 0,6=日/土, 1,3,5=月水金")" >&2
    printf '  %s ' "$(color "$C_BOLD$C_GREEN" "曜日 (例: 0 または 1,3,5) [${DEFAULT_SCHEDULE_DAYS}]:")" >&2
    read -r value
    value="${value:-$DEFAULT_SCHEDULE_DAYS}"
    case "$value" in
      daily|毎日)
        printf '*\n'
        return 0
        ;;
      weekdays|weekday|平日)
        printf '1-5\n'
        return 0
        ;;
      weekends|weekend|土日)
        printf '0,6\n'
        return 0
        ;;
    esac
    if [[ "$value" =~ ^(\*|[0-7](-[0-7])?(,[0-7](-[0-7])?)*)$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    printf '%s\n' "$(color "$C_RED" "❌ 曜日は cron 形式で入力してください。例: *, 1-5, 0,6, 1,3,5")" >&2
  done
}

prompt_max_runtime() {
  local value
  local amount
  local unit

  while true; do
    printf '%s ' "$(color "$C_BOLD$C_GREEN" "⏱️  最大実行時間を入力してください [5h] (最大5h/300m):")" >&2
    read -r value
    value="${value:-5h}"
    if [[ "$value" =~ ^([1-9][0-9]*)([hm])$ ]]; then
      amount="${BASH_REMATCH[1]}"
      unit="${BASH_REMATCH[2]}"
      if { [[ "$unit" == "h" ]] && (( amount <= 5 )); } || { [[ "$unit" == "m" ]] && (( amount <= 300 )); }; then
        printf '%s\n' "$value"
        return 0
      fi
    fi
    printf '%s\n' "$(color "$C_RED" "❌ 最大実行時間は 5h または 300m 以内で入力してください。例: 2h, 90m, 5h")" >&2
  done
}

run_menu_command() {
  local status

  set +e
  ( "$@" )
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "$(color "$C_RED" "❌ コマンドが失敗しました: $*")"
    printf '  exit code: %s\n' "$status"
  fi
  MENU_COMMAND_STATUS="$status"
  return 0
}

prompt_cron_index() {
  local count
  local value

  count="$(managed_cron_count)"
  if [[ "$count" -eq 0 ]]; then
    printf '%s\n' "$(color "$C_YELLOW" "⚠️  管理対象 cron はありません。")" >&2
    return 1
  fi

  while true; do
    printf '%s ' "$(color "$C_BOLD$C_GREEN" "対象番号を入力してください [1-${count}]:")" >&2
    read -r value
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= count )); then
      printf '%s\n' "$value"
      return 0
    fi
    printf '%s\n' "$(color "$C_RED" "❌ 1-${count} の番号を入力してください。")" >&2
  done
}

confirm_yes() {
  local prompt="$1"
  local value

  printf '%s ' "$(color "$C_RED" "${prompt} [y/N]:")" >&2
  read -r value
  [[ "${value,,}" == "y" || "${value,,}" == "yes" ]]
}

confirm_delete_all() {
  local value

  printf '%s ' "$(color "$C_RED" "⚠️  管理対象 cron を全削除します。DELETE と入力してください:")" >&2
  read -r value
  [[ "$value" == "DELETE" ]]
}

manage_cron_interactive() {
  local choice
  local idx
  local line
  local max_runtime
  local project
  local schedule_days
  local schedule_time

  while true; do
    list_managed_cron
    printf '\n%s\n' "$(color "$C_BOLD$C_MAGENTA" "🗓️  cron 管理")"
    menu_item "1." "🛠️" "設定変更" "曜日・時刻・最大実行時間"
    menu_item "2." "🗑️" "選択削除" "対象 cron を削除"
    menu_item "3." "🧹" "全削除" "ai-nightly cron を全削除"
    menu_item "0." "↩️" "戻る"
    printf '\n%s ' "$(color "$C_BOLD$C_GREEN" "👉 選択してください:")"
    read -r choice

    case "${choice^^}" in
      1)
        idx="$(prompt_cron_index)" || continue
        line="$(managed_cron_line_by_index "$idx")"
        [[ -n "$line" ]] || continue
        project="$(cron_project_from_line "$line")"
        printf '%s\n' "$(color "$C_BOLD$C_CYAN" "🛠️  設定変更: ${project}")"
        schedule_days="$(prompt_schedule_days)"
        schedule_time="$(prompt_schedule_time)"
        max_runtime="$(prompt_max_runtime)"
        run_menu_command update_managed_cron "$line" "$schedule_days" "$schedule_time" "$max_runtime"
        if [[ "${MENU_COMMAND_STATUS:-1}" -eq 0 ]]; then
          printf '%s\n' "$(color "$C_GREEN" "✅ cron 設定を更新しました。")"
        fi
        ;;
      2)
        idx="$(prompt_cron_index)" || continue
        line="$(managed_cron_line_by_index "$idx")"
        [[ -n "$line" ]] || continue
        project="$(cron_project_from_line "$line")"
        if confirm_yes "削除します: ${project}"; then
          run_menu_command delete_managed_cron_line "$line"
          if [[ "${MENU_COMMAND_STATUS:-1}" -eq 0 ]]; then
            printf '%s\n' "$(color "$C_GREEN" "✅ cron 設定を削除しました。")"
          fi
        else
          printf '%s\n' "$(color "$C_YELLOW" "削除をキャンセルしました。")"
        fi
        ;;
      3)
        if confirm_delete_all; then
          run_menu_command delete_all_managed_cron
          if [[ "${MENU_COMMAND_STATUS:-1}" -eq 0 ]]; then
            printf '%s\n' "$(color "$C_GREEN" "✅ 管理対象 cron を全削除しました。")"
          fi
        else
          printf '%s\n' "$(color "$C_YELLOW" "全削除をキャンセルしました。")"
        fi
        ;;
      0|Q|QUIT|EXIT)
        return 0
        ;;
      *)
        printf '%s\n' "$(color "$C_RED" "❌ 無効な選択です。")"
        ;;
    esac
    printf '\n'
  done
}

menu_item() {
  local key="$1"
  local icon="$2"
  local label="$3"
  local note="${4:-}"
  if [[ -n "$note" ]]; then
    printf '  %s %s  %s  %s\n' "$(color "$C_YELLOW" "$key")" "$icon" "$(color "$C_WHITE" "$label")" "$(color "$C_CYAN" "[$note]")"
  else
    printf '  %s %s  %s\n' "$(color "$C_YELLOW" "$key")" "$icon" "$(color "$C_WHITE" "$label")"
  fi
}

show_menu() {
  clear 2>/dev/null || true
  printf '\n'
  printf '%s\n' "$(color "$C_BOLD$C_CYAN" "╔════════════════════════════════════════════════════════════╗")"
  printf '%s\n' "$(color "$C_BOLD$C_CYAN" "║")$(color "$C_BOLD$C_WHITE" "  🚀 Linux Codex StartUp Tools")$(color "$C_YELLOW" "  Bash / Codex CLI / cron")$(color "$C_BOLD$C_CYAN" "       ║")"
  printf '%s\n' "$(color "$C_BOLD$C_CYAN" "╚════════════════════════════════════════════════════════════╝")"
  printf '\n'
  show_startup_dashboard
  printf '\n'
  printf '%s\n' "$(color "$C_BOLD$C_MAGENTA" "🧭 管理メニュー")"
  menu_item "1." "📊" "ダッシュボード表示" "状態・設定・検出数"
  menu_item "2." "📦" "プロジェクト一覧" "$PROJECTS_DIR"
  menu_item "3." "🤖" "Codex 起動" "選択プロジェクトで起動"
  menu_item "4." "🧪" "Codex 起動 dry-run" "実行せず計画確認"
  menu_item "5." "🕛" "nightly 自動セットアップ + cron 登録" "曜日・時刻・最大実行時間指定"
  menu_item "6." "🔍" "nightly dry-run" "設定検証"
  menu_item "7." "🚀" "nightly 今すぐバックグラウンド実行" "nohup 相当"
  menu_item "8." "🕘" "最近のプロジェクト" "起動履歴"
  menu_item "9." "🗓️" "管理 cron" "一覧・変更・削除"
  menu_item "10." "✅" "make verify" "構文・lint・テスト"
  menu_item "11." "📋" "Codex goal prompt 起動" "codex_goal_prompt.md を goal として実行"
  menu_item "12." "🔄" "モデル使用量管理" "状況確認・リセット・週間上限マーク"
  menu_item "0." "🚪" "終了"
  printf '\n'
}

run_action() {
  local action="$1"
  local project_path

  case "$action" in
    dashboard)
      show_startup_dashboard
      ;;
    list-projects)
      list_projects "$PROJECTS_DIR" "$MENU_MAX_PROJECTS"
      ;;
    recent)
      show_recent_projects 15
      ;;
    verify)
      make -C "$AI_NIGHTLY_ROOT" verify
      ;;
    cron-list)
      list_managed_cron
      ;;
    run-nightly-bg)
      run_nightly_background
      ;;
    help)
      usage
      ;;
    *)
      die "unknown --once action: $action"
      ;;
  esac
}

interactive_loop() {
  local choice
  local -a auto_setup_args
  local project_path
  local schedule_days
  local max_runtime
  local schedule_time
  local task_file
  local model_choice

  while true; do
    show_menu
    printf '%s ' "$(color "$C_BOLD$C_GREEN" "👉 選択してください:")"
    read -r choice
    case "${choice^^}" in
      1)
        show_startup_dashboard
        wait_enter
        ;;
      2)
        list_projects "$PROJECTS_DIR" "$MENU_MAX_PROJECTS"
        wait_enter
        ;;
      3)
        project_path="$(select_project_interactive)"
        run_menu_command "$SCRIPT_DIR/codex_startup.sh" --project "$project_path"
        wait_enter
        ;;
      4)
        project_path="$(select_project_interactive)"
        run_menu_command "$SCRIPT_DIR/codex_startup.sh" --project "$project_path" --dry-run
        wait_enter
        ;;
      5)
        project_path="$(select_project_interactive)"
        schedule_days="$(prompt_schedule_days)"
        schedule_time="$(prompt_schedule_time)"
        max_runtime="$(prompt_max_runtime)"
        printf '%s\n' "$(color "$C_BOLD$C_CYAN" "🧾 登録内容")"
        printf '  Project     : %s\n' "$project_path"
        printf '  Cron days   : %s\n' "$schedule_days"
        printf '  Cron time   : %s\n' "$schedule_time"
        printf '  Max runtime : %s\n' "$max_runtime"
        auto_setup_args=(
          "$SCRIPT_DIR/auto_setup.sh"
          --repo "$project_path"
          --config "$NIGHTLY_CONFIG_FILE"
          --env "$NIGHTLY_ENV_FILE"
          --force
          --days "$schedule_days"
          --time "$schedule_time"
          --max-runtime "$max_runtime"
        )
        if [[ "$AUTO_SETUP_VERIFY" != "true" ]]; then
          auto_setup_args+=(--no-verify)
        fi
        run_menu_command "${auto_setup_args[@]}"
        if [[ "${MENU_COMMAND_STATUS:-1}" -eq 0 ]]; then
          printf '\n%s\n' "$(color "$C_BOLD$C_CYAN" "✅ 登録後確認")"
          list_managed_cron
          if [[ -f "$NIGHTLY_CONFIG_FILE" ]]; then
            run_menu_command "$SCRIPT_DIR/nightly_codex.sh" --config "$NIGHTLY_CONFIG_FILE" --dry-run
          fi
        fi
        wait_enter
        ;;
      6)
        if [[ -f "$NIGHTLY_CONFIG_FILE" ]]; then
          run_menu_command "$SCRIPT_DIR/nightly_codex.sh" --config "$NIGHTLY_CONFIG_FILE" --dry-run
        else
          printf '%s\n' "$(color "$C_YELLOW" "⚠️  config/jobs.conf がありません。先に 5 を実行してください。")"
        fi
        wait_enter
        ;;
      7)
        if [[ -f "$NIGHTLY_CONFIG_FILE" ]]; then
          run_menu_command run_nightly_background "$NIGHTLY_CONFIG_FILE" "$NIGHTLY_ENV_FILE"
        else
          printf '%s\n' "$(color "$C_YELLOW" "⚠️  config/jobs.conf がありません。先に 5 を実行してください。")"
        fi
        wait_enter
        ;;
      8)
        show_recent_projects 15
        wait_enter
        ;;
      9)
        manage_cron_interactive
        ;;
      10)
        run_menu_command make -C "$AI_NIGHTLY_ROOT" verify
        wait_enter
        ;;
      11)
        project_path="$(select_project_interactive)"
        task_file="$AI_NIGHTLY_ROOT/tasks/codex_goal_prompt.md"
        if [[ -f "$task_file" ]]; then
          printf '\n%s\n' "$(color "$C_BOLD$C_CYAN" "📋 Codex goal prompt 起動")"
          printf '  Project : %s\n' "$project_path"
          printf '  Task    : %s\n' "$task_file"
          printf '%s\n' "$(color "$C_YELLOW" "⏳ codex exec を起動しています... (長時間実行になる場合があります)")"
          run_menu_command "$SCRIPT_DIR/codex_startup.sh" \
            --project "$project_path" \
            --task "$task_file" \
            --profile yolo \
            --interactive \
            --model-auto
        else
          printf '%s\n' "$(color "$C_YELLOW" "⚠️  tasks/codex_goal_prompt.md が見つかりません。")"
        fi
        wait_enter
        ;;
      12)
        printf '\n%s\n' "$(color "$C_BOLD$C_CYAN" "🔄 モデル使用量管理")"
        model_usage_status_line
        printf '\n%s\n' "$(color "$C_BOLD$C_MAGENTA" "操作を選択してください")"
        printf '  %s %s\n' "$(color "$C_YELLOW" "1.")" "$(color "$C_WHITE" "全リセット（両モデルの使用量を0に）")"
        printf '  %s %s\n' "$(color "$C_YELLOW" "2.")" "$(color "$C_WHITE" "プライマリ($MODEL_PRIMARY)のみリセット")"
        printf '  %s %s\n' "$(color "$C_YELLOW" "3.")" "$(color "$C_WHITE" "フォールバック($MODEL_FALLBACK)のみリセット")"
        printf '  %s %s\n' "$(color "$C_YELLOW" "4.")" "$(color "$C_WHITE" "プライマリを週間上限済みとしてマーク")"
        printf '  %s %s\n' "$(color "$C_YELLOW" "5.")" "$(color "$C_WHITE" "フォールバックを週間上限済みとしてマーク")"
        printf '  %s %s\n' "$(color "$C_YELLOW" "0.")" "$(color "$C_WHITE" "戻る")"
        printf '\n%s ' "$(color "$C_BOLD$C_GREEN" "👉 選択:")"
        read -r model_choice
        case "${model_choice}" in
          1) run_menu_command model_usage_reset all
             [[ "${MENU_COMMAND_STATUS:-1}" -eq 0 ]] && printf '%s\n' "$(color "$C_GREEN" "✅ 全リセット完了")" ;;
          2) run_menu_command model_usage_reset primary
             [[ "${MENU_COMMAND_STATUS:-1}" -eq 0 ]] && printf '%s\n' "$(color "$C_GREEN" "✅ プライマリリセット完了")" ;;
          3) run_menu_command model_usage_reset fallback
             [[ "${MENU_COMMAND_STATUS:-1}" -eq 0 ]] && printf '%s\n' "$(color "$C_GREEN" "✅ フォールバックリセット完了")" ;;
          4) run_menu_command model_usage_mark_exhausted "$MODEL_PRIMARY"
             [[ "${MENU_COMMAND_STATUS:-1}" -eq 0 ]] && printf '%s\n' "$(color "$C_YELLOW" "⛔ $MODEL_PRIMARY を週間上限済みとしてマークしました")" ;;
          5) run_menu_command model_usage_mark_exhausted "$MODEL_FALLBACK"
             [[ "${MENU_COMMAND_STATUS:-1}" -eq 0 ]] && printf '%s\n' "$(color "$C_YELLOW" "⛔ $MODEL_FALLBACK を週間上限済みとしてマークしました")" ;;
          0) : ;;
          *) printf '%s\n' "$(color "$C_RED" "❌ 無効な選択です。")" ;;
        esac
        wait_enter
        ;;
      0|Q|QUIT|EXIT)
        printf '%s\n' "$(color "$C_CYAN" "👋 終了します。")"
        break
        ;;
      *)
        printf '%s\n' "$(color "$C_RED" "❌ 無効な選択です。")"
        sleep 1
        ;;
    esac
  done
}

ONCE_ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) ONCE_ACTION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_startup_config

if [[ -n "$ONCE_ACTION" ]]; then
  run_action "$ONCE_ACTION"
else
  interactive_loop
fi
