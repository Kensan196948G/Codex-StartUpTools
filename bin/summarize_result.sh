#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: summarize_result.sh --meta FILE --report FILE --log FILE --diff-stat FILE --status FILE --task FILE

Creates the morning review Markdown report for a nightly Codex job.
USAGE
}

META_FILE=""
REPORT_FILE=""
LOG_FILE=""
DIFF_STAT_FILE=""
STATUS_FILE=""
TASK_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --meta) META_FILE="$2"; shift 2 ;;
    --report) REPORT_FILE="$2"; shift 2 ;;
    --log) LOG_FILE="$2"; shift 2 ;;
    --diff-stat) DIFF_STAT_FILE="$2"; shift 2 ;;
    --status) STATUS_FILE="$2"; shift 2 ;;
    --task) TASK_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -f "$META_FILE" ]] || die "meta file not found: $META_FILE"
[[ -f "$LOG_FILE" ]] || die "log file not found: $LOG_FILE"
[[ -f "$DIFF_STAT_FILE" ]] || die "diff stat file not found: $DIFF_STAT_FILE"
[[ -f "$STATUS_FILE" ]] || die "status file not found: $STATUS_FILE"
[[ -f "$TASK_FILE" ]] || die "task file not found: $TASK_FILE"
ensure_dir "$(dirname "$REPORT_FILE")"

job_id="$(read_meta_value "$META_FILE" job_id || printf 'unknown')"
started_at="$(read_meta_value "$META_FILE" started_at || printf 'unknown')"
ended_at="$(read_meta_value "$META_FILE" ended_at || printf 'unknown')"
repo_name="$(read_meta_value "$META_FILE" repo_name || printf 'unknown')"
repo_path="$(read_meta_value "$META_FILE" repo_path || printf 'unknown')"
branch_name="$(read_meta_value "$META_FILE" branch_name || printf 'unknown')"
exit_code="$(read_meta_value "$META_FILE" exit_code || printf 'unknown')"
test_exit_code="$(read_meta_value "$META_FILE" test_exit_code || printf 'not_run')"
lint_exit_code="$(read_meta_value "$META_FILE" lint_exit_code || printf 'not_run')"
build_exit_code="$(read_meta_value "$META_FILE" build_exit_code || printf 'not_run')"
autonomy_level="$(read_meta_value "$META_FILE" autonomy_level || printf 'unknown')"
pr_mode="$(read_meta_value "$META_FILE" pr_mode || printf 'unknown')"
final_message_file="$(read_meta_value "$META_FILE" final_message_file || printf '')"
pr_draft_file="$(read_meta_value "$META_FILE" pr_draft_file || printf '')"
pr_url_file="$(read_meta_value "$META_FILE" pr_url_file || printf '')"

{
  printf '# Nightly Codex Report\n\n'
  printf '## 概要\n\n'
  printf -- "- Job ID: \`%s\`\n" "$job_id"
  printf -- "- 開始: \`%s\`\n" "$started_at"
  printf -- "- 終了: \`%s\`\n" "$ended_at"
  printf -- "- 対象: \`%s\` (\`%s\`)\n" "$repo_name" "$repo_path"
  printf -- "- ブランチ: \`%s\`\n" "$branch_name"
  printf -- "- 自律レベル: \`%s\`\n" "$autonomy_level"
  printf -- "- PR モード: \`%s\`\n" "$pr_mode"
  printf -- "- Codex 終了コード: \`%s\`\n" "$exit_code"
  if [[ -n "$final_message_file" && -s "$final_message_file" ]]; then
    printf '\n## Codex 最終応答\n\n'
    sed -n '1,160p' "$final_message_file"
    printf '\n'
  fi
  printf '\n## タスク\n\n'
  sed 's/^/> /' "$TASK_FILE"
  printf '\n\n## 変更ファイル一覧\n\n'
  if [[ -s "$STATUS_FILE" ]]; then
    printf '```text\n'
    cat "$STATUS_FILE"
    printf '\n```\n'
  else
    printf 'Git status 上の変更はありません。\n'
  fi
  printf '\n## Diff Stat\n\n'
  if [[ -s "$DIFF_STAT_FILE" ]]; then
    printf '```text\n'
    cat "$DIFF_STAT_FILE"
    printf '\n```\n'
  else
    printf '変更差分はありません。\n'
  fi
  printf '\n## 検証結果\n\n'
  printf -- "- Test: \`%s\`\n" "$test_exit_code"
  printf -- "- Lint: \`%s\`\n" "$lint_exit_code"
  printf -- "- Build: \`%s\`\n" "$build_exit_code"
  printf '\n## 朝の確認ポイント\n\n'
  printf -- "- \`%s\` の差分とログを確認してください。\n" "$branch_name"
  printf -- "- 検証コードが \`0\` 以外の場合は、該当ログを優先して確認してください。\n"
  printf -- "- 意図しない秘密情報、絶対パス、破壊的変更が含まれていないか確認してください。\n"
  printf '\n## 参照ファイル\n\n'
  printf -- "- Log: \`%s\`\n" "$LOG_FILE"
  printf -- "- Meta: \`%s\`\n" "$META_FILE"
  printf -- "- Status: \`%s\`\n" "$STATUS_FILE"
  printf -- "- Diff stat: \`%s\`\n" "$DIFF_STAT_FILE"
  if [[ -n "$pr_draft_file" ]]; then
    printf -- "- PR draft: \`%s\`\n" "$pr_draft_file"
  fi
  if [[ -n "$pr_url_file" && -s "$pr_url_file" ]]; then
    printf -- "- PR URL: \`%s\`\n" "$(cat "$pr_url_file")"
  fi
} >"$REPORT_FILE"

log "wrote report: $REPORT_FILE"
