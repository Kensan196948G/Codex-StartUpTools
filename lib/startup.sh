#!/usr/bin/env bash

set -euo pipefail

STARTUP_CONFIG_FILE="${STARTUP_CONFIG_FILE:-$AI_NIGHTLY_ROOT/config/startup.conf}"

if [[ "${NO_COLOR:-}" == "" ]] && { [[ -t 1 ]] || [[ "${FORCE_COLOR:-}" == "1" ]]; }; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=""
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'
  C_MAGENTA=$'\033[1;35m'
  C_CYAN=$'\033[1;36m'
  C_WHITE=$'\033[1;37m'
else
  # Color variables are consumed by scripts that source this library.
  # shellcheck disable=SC2034
  C_RESET=""
  # shellcheck disable=SC2034
  C_BOLD=""
  # shellcheck disable=SC2034
  C_DIM=""
  # shellcheck disable=SC2034
  C_RED=""
  # shellcheck disable=SC2034
  C_GREEN=""
  # shellcheck disable=SC2034
  C_YELLOW=""
  # shellcheck disable=SC2034
  C_BLUE=""
  # shellcheck disable=SC2034
  C_MAGENTA=""
  # shellcheck disable=SC2034
  C_CYAN=""
  # shellcheck disable=SC2034
  C_WHITE=""
fi

color() {
  local c="$1"
  shift
  printf '%s%s%s' "$c" "$*" "$C_RESET"
}

load_startup_config() {
  if [[ -f "$STARTUP_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STARTUP_CONFIG_FILE"
  fi

  PROJECTS_DIR="${PROJECTS_DIR:-/home/kensan/Projects}"
  CODEX_COMMAND="${CODEX_COMMAND:-codex}"
  CODEX_ARGS="${CODEX_ARGS:-}"
  STARTUP_LOG_DIR="${STARTUP_LOG_DIR:-$AI_NIGHTLY_ROOT/logs/startup}"
  RECENT_PROJECTS_FILE="${RECENT_PROJECTS_FILE:-$AI_NIGHTLY_ROOT/state/recent-projects.tsv}"
  MENU_MAX_PROJECTS="${MENU_MAX_PROJECTS:-80}"
  DEFAULT_SCHEDULE="${DEFAULT_SCHEDULE:-00:00}"
  DEFAULT_SCHEDULE_DAYS="${DEFAULT_SCHEDULE_DAYS:-*}"
  NIGHTLY_CONFIG_FILE="${NIGHTLY_CONFIG_FILE:-$AI_NIGHTLY_ROOT/config/jobs.conf}"
  NIGHTLY_ENV_FILE="${NIGHTLY_ENV_FILE:-$AI_NIGHTLY_ROOT/config/env.sh}"
  AUTO_SETUP_VERIFY="${AUTO_SETUP_VERIFY:-true}"
  ensure_dir "$STARTUP_LOG_DIR"
  ensure_dir "$(dirname "$RECENT_PROJECTS_FILE")"
}

resolve_project_path() {
  local project="${1:-}"

  if [[ -z "$project" ]]; then
    printf '%s\n' "$PROJECTS_DIR"
    return 0
  fi

  if [[ "$project" = /* ]]; then
    printf '%s\n' "$project"
    return 0
  fi

  printf '%s/%s\n' "$PROJECTS_DIR" "$project"
}

project_name_from_path() {
  basename "$1"
}

list_projects() {
  local base="${1:-$PROJECTS_DIR}"
  local max="${2:-$MENU_MAX_PROJECTS}"

  [[ -d "$base" ]] || return 0
  find "$base" -mindepth 1 -maxdepth 1 -type d \
    ! -name '.*' \
    ! -name 'node_modules' \
    ! -name 'logs' \
    ! -name 'reports' \
    -printf '%f\n' | sort | sed -n "1,${max}p"
}

record_recent_project() {
  local project_path="$1"
  local result="${2:-unknown}"
  local elapsed_ms="${3:-0}"
  local project_name
  project_name="$(project_name_from_path "$project_path")"

  ensure_dir "$(dirname "$RECENT_PROJECTS_FILE")"
  printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$project_name" "$result" "$elapsed_ms" >>"$RECENT_PROJECTS_FILE"
}

show_recent_projects() {
  local limit="${1:-10}"
  if [[ ! -s "$RECENT_PROJECTS_FILE" ]]; then
    printf '🕘 履歴はまだありません。\n'
    return 0
  fi

  tail -n "$limit" "$RECENT_PROJECTS_FILE" | tac | awk -F '\t' '{
    icon = ($3 == "success") ? "✅" : (($3 == "failure") ? "❌" : (($3 == "dry-run") ? "🧪" : "•"))
    printf "%s %2d. %-32s %-8s %s\n", icon, NR, $2, $3, $1
  }'
}

show_startup_dashboard() {
  local codex_path
  local today_logs
  local project_count
  codex_path="$(command -v "$CODEX_COMMAND" 2>/dev/null || printf 'not found')"
  today_logs="$(find "$STARTUP_LOG_DIR" -type f -name '*.log' -mtime -1 2>/dev/null | wc -l)"
  project_count="$(list_projects "$PROJECTS_DIR" "$MENU_MAX_PROJECTS" | wc -l)"

  printf '%s\n' "$(color "$C_BOLD$C_CYAN" "🚀 Codex StartUp ダッシュボード")"
  printf '  🏠 %s : %s\n' "$(color "$C_YELLOW" "ルート       ")" "$(color "$C_WHITE" "$AI_NIGHTLY_ROOT")"
  printf '  📁 %s : %s\n' "$(color "$C_YELLOW" "プロジェクト ")" "$(color "$C_WHITE" "$PROJECTS_DIR")"
  if [[ "$codex_path" == "not found" ]]; then
    printf '  🤖 %s : %s\n' "$(color "$C_YELLOW" "Codex        ")" "$(color "$C_RED" "未検出")"
  else
    printf '  🤖 %s : %s\n' "$(color "$C_YELLOW" "Codex        ")" "$(color "$C_GREEN" "$codex_path")"
  fi
  printf '  ⚙️  %s : %s\n' "$(color "$C_YELLOW" "設定         ")" "$(color "$C_WHITE" "$STARTUP_CONFIG_FILE")"
  printf '  🕘 %s : %s\n' "$(color "$C_YELLOW" "履歴         ")" "$(color "$C_WHITE" "$RECENT_PROJECTS_FILE")"
  printf '  🧾 %s : %s\n' "$(color "$C_YELLOW" "ログ         ")" "$(color "$C_WHITE" "$STARTUP_LOG_DIR")"
  printf '  📊 %s : %s\n' "$(color "$C_YELLOW" "本日のログ   ")" "$(color "$C_WHITE" "$today_logs")"
  printf '  📦 %s : %s\n' "$(color "$C_YELLOW" "検出PJ数     ")" "$(color "$C_WHITE" "$project_count")"
}

select_project_interactive() {
  local projects=()
  local idx=1
  local choice

  mapfile -t projects < <(list_projects "$PROJECTS_DIR" "$MENU_MAX_PROJECTS")
  printf '\n%s %s\n' "📦" "$(color "$C_BOLD$C_CYAN" "プロジェクト一覧: $PROJECTS_DIR")" >&2
  if [[ "${#projects[@]}" -eq 0 ]]; then
    printf '  ⚠️  プロジェクトが見つかりません\n' >&2
  else
    for p in "${projects[@]}"; do
      printf '  %s %s %s\n' "📁" "$(color "$C_YELLOW" "$(printf '%2d.' "$idx")")" "$(color "$C_WHITE" "$p")" >&2
      idx=$((idx + 1))
    done
  fi
  printf '  %s %s %s\n\n' "🏠" "$(color "$C_YELLOW" " 0.")" "$(color "$C_CYAN" "ベースディレクトリ")" >&2
  printf '%s ' "$(color "$C_BOLD$C_GREEN" "🔎 番号またはプロジェクト名/絶対パスを入力:")" >&2
  read -r choice

  if [[ -z "$choice" || "$choice" == "0" ]]; then
    printf '%s\n' "$PROJECTS_DIR"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#projects[@]} )); then
    resolve_project_path "${projects[$((choice - 1))]}"
  else
    resolve_project_path "$choice"
  fi
}

managed_cron_entries() {
  crontab -l 2>/dev/null | grep -F '# ai-nightly:' || true
}

managed_cron_line_by_index() {
  local idx=1
  local line
  local target="$1"

  managed_cron_entries | while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$idx" -eq "$target" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
    idx=$((idx + 1))
  done
}

managed_cron_count() {
  managed_cron_entries | sed '/^$/d' | wc -l
}

cron_project_from_line() {
  local line="$1"
  if [[ "$line" == *"# ai-nightly:"* ]]; then
    printf '%s\n' "${line##*# ai-nightly:}"
  else
    printf 'unknown\n'
  fi
}

cron_config_from_line() {
  local config_file="$1"
  if [[ "$config_file" == *"--config "* ]]; then
    config_file="${config_file#*--config }"
    config_file="${config_file%% *}"
  else
    config_file="unknown"
  fi
  printf '%s\n' "$config_file"
}

list_managed_cron() {
  local config_file
  local day_of_week
  local entries
  local hour
  local idx=1
  local line
  local minute
  local project
  entries="$(managed_cron_entries)"
  if [[ -z "$entries" ]]; then
    printf '🕒 管理対象 cron はありません。\n'
  else
    printf '🕒 管理対象 cron:\n'
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      read -r minute hour _ _ day_of_week _ <<<"$line"
      project="$(cron_project_from_line "$line")"
      config_file="$(cron_config_from_line "$line")"

      printf '  %s %s\n' "$(color "$C_YELLOW" "$(printf '%2d.' "$idx")")" "$(color "$C_WHITE" "📦 ${project}")"
      printf '      %s %s\n' "$(color "$C_CYAN" "曜日 :")" "$(color "$C_WHITE" "$(cron_days_label "$day_of_week")")"
      printf '      %s %s\n' "$(color "$C_CYAN" "時刻 :")" "$(color "$C_WHITE" "${hour}:${minute}")"
      printf '      %s %s\n' "$(color "$C_CYAN" "設定 :")" "$(color "$C_WHITE" "$config_file")"
      printf '      %s %s\n' "$(color "$C_CYAN" "cron :")" "$line"
      idx=$((idx + 1))
    done <<<"$entries"
  fi
}

replace_managed_cron_line() {
  local current
  local new_line="$2"
  local old_line="$1"

  require_command crontab
  current="$(crontab -l 2>/dev/null || true)"
  printf '%s\n' "$current" | awk -v old="$old_line" -v new="$new_line" '
    $0 == old && replaced == 0 { print new; replaced = 1; next }
    { print }
  ' | crontab -
}

delete_managed_cron_line() {
  local current
  local line="$1"

  require_command crontab
  current="$(crontab -l 2>/dev/null || true)"
  printf '%s\n' "$current" | awk -v target="$line" '
    $0 == target && removed == 0 { removed = 1; next }
    { print }
  ' | crontab -
}

delete_all_managed_cron() {
  local current

  require_command crontab
  current="$(crontab -l 2>/dev/null || true)"
  printf '%s\n' "$current" | awk 'index($0, "# ai-nightly:") == 0 { print }' | crontab -
}

update_config_max_runtime() {
  local config_file="$1"
  local max_runtime="$2"
  local quoted_runtime
  local tmp_file

  [[ -f "$config_file" ]] || die "config file not found: $config_file"
  quoted_runtime="$(printf '%q' "$max_runtime")"
  tmp_file="${config_file}.tmp.$$"
  awk -v replacement="MAX_RUNTIME=${quoted_runtime}" '
    BEGIN { replaced = 0 }
    /^MAX_RUNTIME=/ { print replacement; replaced = 1; next }
    { print }
    END { if (replaced == 0) print replacement }
  ' "$config_file" >"$tmp_file"
  mv "$tmp_file" "$config_file"
}

update_managed_cron() {
  local config_file
  local day_of_week
  local hour
  local line="$1"
  local max_runtime="$4"
  local minute
  local month
  local new_days="$2"
  local new_hour
  local new_line
  local new_minute
  local new_time="$3"
  local rest
  local day_of_month

  read -r minute hour day_of_month month day_of_week rest <<<"$line"
  rest="${line#"$minute $hour $day_of_month $month $day_of_week "}"
  new_hour="${new_time%:*}"
  new_minute="${new_time#*:}"
  new_line="${new_minute} ${new_hour} ${day_of_month} ${month} ${new_days} ${rest}"

  replace_managed_cron_line "$line" "$new_line"
  config_file="$(cron_config_from_line "$line")"
  if [[ "$config_file" != "unknown" ]]; then
    update_config_max_runtime "$config_file" "$max_runtime"
  fi
}

cron_day_name() {
  case "$1" in
    0|7) printf '日' ;;
    1) printf '月' ;;
    2) printf '火' ;;
    3) printf '水' ;;
    4) printf '木' ;;
    5) printf '金' ;;
    6) printf '土' ;;
    *) printf '%s' "$1" ;;
  esac
}

cron_day_token_label() {
  local end
  local start
  local token="$1"

  if [[ "$token" =~ ^([0-7])-([0-7])$ ]]; then
    start="${BASH_REMATCH[1]}"
    end="${BASH_REMATCH[2]}"
    printf '%s-%s' "$(cron_day_name "$start")" "$(cron_day_name "$end")"
  else
    cron_day_name "$token"
  fi
}

cron_days_label() {
  local IFS=,
  local labels=()
  local token
  local value="$1"

  if [[ "$value" == "*" ]]; then
    printf '毎日 (*)'
    return 0
  fi

  for token in $value; do
    labels+=("$(cron_day_token_label "$token")")
  done

  (IFS=,; printf '%s (%s)' "${labels[*]}" "$value")
}

run_nightly_background() {
  local config_file="${1:-$AI_NIGHTLY_ROOT/config/jobs.conf}"
  local env_file="${2:-$AI_NIGHTLY_ROOT/config/env.sh}"
  local extra_arg="${3:-}"
  local bg_dir="$AI_NIGHTLY_ROOT/logs/background"
  local log_file
  local pid_file="$AI_NIGHTLY_ROOT/run/nightly-background.pid"

  [[ -f "$config_file" ]] || die "config file not found: $config_file"
  ensure_dir "$bg_dir"
  ensure_dir "$(dirname "$pid_file")"
  log_file="$bg_dir/nightly-background-$(date '+%Y%m%d-%H%M%S').log"

  (
    cd "$AI_NIGHTLY_ROOT"
    if [[ -f "$env_file" ]]; then
      # shellcheck disable=SC1090
      source "$env_file"
    fi
    if [[ -n "$extra_arg" ]]; then
      exec "$AI_NIGHTLY_ROOT/bin/nightly_codex.sh" --config "$config_file" "$extra_arg"
    else
      exec "$AI_NIGHTLY_ROOT/bin/nightly_codex.sh" --config "$config_file"
    fi
  ) >>"$log_file" 2>&1 &

  local pid=$!
  printf '%s\n' "$pid" >"$pid_file"
  printf '🚀 nightly をバックグラウンド起動しました。\n'
  printf '  PID : %s\n' "$pid"
  printf '  Log : %s\n' "$log_file"
  printf '  PID file: %s\n' "$pid_file"
}

remove_managed_cron() {
  local marker="$1"
  [[ -n "$marker" ]] || die "cron marker is required"
  require_command crontab

  crontab -l 2>/dev/null | grep -Fv "$marker" | crontab -
}
