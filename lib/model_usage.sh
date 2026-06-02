#!/usr/bin/env bash

# Model auto-failover: track 5h usage per model, switch at ≤10% remaining.
# Requires lib/common.sh (log, ensure_dir) to be sourced before this file.

set -euo pipefail

MODEL_USAGE_FILE="${MODEL_USAGE_FILE:-$AI_NIGHTLY_ROOT/state/model_usage.conf}"
MODEL_PRIMARY="${MODEL_PRIMARY:-gpt-5.3-codex-spark}"
MODEL_FALLBACK="${MODEL_FALLBACK:-gpt-5.5}"
MODEL_SESSION_LIMIT="${MODEL_SESSION_LIMIT:-18000}"  # 5h = 18000s
MODEL_SWITCH_THRESHOLD="${MODEL_SWITCH_THRESHOLD:-10}"  # % remaining before switch

_model_threshold_seconds() {
  printf '%d\n' $(( MODEL_SESSION_LIMIT * MODEL_SWITCH_THRESHOLD / 100 ))
}

_model_week_start() {
  local dow
  dow="$(date '+%u')"  # 1=Mon ... 7=Sun
  date -d "$(( dow - 1 )) days ago" '+%Y-%m-%d'
}

_model_usage_defaults() {
  MODEL_USAGE_WEEK_START="${MODEL_USAGE_WEEK_START:-$(_model_week_start)}"
  MODEL_PRIMARY_SECONDS_USED="${MODEL_PRIMARY_SECONDS_USED:-0}"
  MODEL_PRIMARY_WEEKLY_EXHAUSTED="${MODEL_PRIMARY_WEEKLY_EXHAUSTED:-false}"
  MODEL_FALLBACK_SECONDS_USED="${MODEL_FALLBACK_SECONDS_USED:-0}"
  MODEL_FALLBACK_WEEKLY_EXHAUSTED="${MODEL_FALLBACK_WEEKLY_EXHAUSTED:-false}"
  CURRENT_MODEL="${CURRENT_MODEL:-$MODEL_PRIMARY}"
}

model_usage_save() {
  ensure_dir "$(dirname "$MODEL_USAGE_FILE")"
  cat >"$MODEL_USAGE_FILE" <<CONF
MODEL_USAGE_WEEK_START=${MODEL_USAGE_WEEK_START}
MODEL_PRIMARY_SECONDS_USED=${MODEL_PRIMARY_SECONDS_USED}
MODEL_PRIMARY_WEEKLY_EXHAUSTED=${MODEL_PRIMARY_WEEKLY_EXHAUSTED}
MODEL_FALLBACK_SECONDS_USED=${MODEL_FALLBACK_SECONDS_USED}
MODEL_FALLBACK_WEEKLY_EXHAUSTED=${MODEL_FALLBACK_WEEKLY_EXHAUSTED}
CURRENT_MODEL=${CURRENT_MODEL}
CONF
}

model_usage_load() {
  if [[ -f "$MODEL_USAGE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MODEL_USAGE_FILE"
  fi
  _model_usage_defaults
}

_model_usage_week_reset_if_needed() {
  local current_week
  current_week="$(_model_week_start)"
  if [[ "${MODEL_USAGE_WEEK_START}" != "$current_week" ]]; then
    log "model-failover: new week ($current_week) — resetting weekly counters"
    MODEL_USAGE_WEEK_START="$current_week"
    MODEL_PRIMARY_SECONDS_USED=0
    MODEL_PRIMARY_WEEKLY_EXHAUSTED=false
    MODEL_FALLBACK_SECONDS_USED=0
    MODEL_FALLBACK_WEEKLY_EXHAUSTED=false
    CURRENT_MODEL="$MODEL_PRIMARY"
    model_usage_save
  fi
}

_model_remaining_seconds() {
  local model="$1"
  local used
  if [[ "$model" == "$MODEL_PRIMARY" ]]; then
    used="${MODEL_PRIMARY_SECONDS_USED:-0}"
  else
    used="${MODEL_FALLBACK_SECONDS_USED:-0}"
  fi
  local remaining=$(( MODEL_SESSION_LIMIT - used ))
  [[ "$remaining" -lt 0 ]] && remaining=0
  printf '%d\n' "$remaining"
}

_model_is_available() {
  local model="$1"
  local threshold
  threshold="$(_model_threshold_seconds)"
  local remaining
  remaining="$(_model_remaining_seconds "$model")"

  if [[ "$model" == "$MODEL_PRIMARY" ]]; then
    [[ "${MODEL_PRIMARY_WEEKLY_EXHAUSTED:-false}" == "true" ]] && return 1
  else
    [[ "${MODEL_FALLBACK_WEEKLY_EXHAUSTED:-false}" == "true" ]] && return 1
  fi

  (( remaining > threshold ))
}

# Print the model to use for the next nightly run.
model_usage_select() {
  model_usage_load
  _model_usage_week_reset_if_needed

  if _model_is_available "$MODEL_PRIMARY"; then
    CURRENT_MODEL="$MODEL_PRIMARY"
  elif _model_is_available "$MODEL_FALLBACK"; then
    log "model-failover: $MODEL_PRIMARY near/at limit → switching to $MODEL_FALLBACK"
    CURRENT_MODEL="$MODEL_FALLBACK"
  else
    log "model-failover: both models near limit — resetting primary usage and using $MODEL_PRIMARY"
    MODEL_PRIMARY_SECONDS_USED=0
    MODEL_PRIMARY_WEEKLY_EXHAUSTED=false
    CURRENT_MODEL="$MODEL_PRIMARY"
  fi

  model_usage_save
  printf '%s\n' "$CURRENT_MODEL"
}

# Record usage after a nightly run.
# Args: model elapsed_seconds codex_exit_code [log_file]
model_usage_record() {
  local model="$1"
  local elapsed="$2"
  local exit_code="${3:-0}"
  local log_file="${4:-}"

  model_usage_load
  _model_usage_week_reset_if_needed

  if [[ "$model" == "$MODEL_PRIMARY" ]]; then
    MODEL_PRIMARY_SECONDS_USED=$(( MODEL_PRIMARY_SECONDS_USED + elapsed ))
    if [[ -n "$log_file" && -f "$log_file" ]] && \
       grep -qiE 'rate.limit|quota.exceeded|weekly.*limit|usage.*limit|insufficient_quota' "$log_file" 2>/dev/null; then
      MODEL_PRIMARY_WEEKLY_EXHAUSTED=true
      log "model-failover: weekly limit detected for $MODEL_PRIMARY → marking exhausted"
    fi
  else
    MODEL_FALLBACK_SECONDS_USED=$(( MODEL_FALLBACK_SECONDS_USED + elapsed ))
    if [[ -n "$log_file" && -f "$log_file" ]] && \
       grep -qiE 'rate.limit|quota.exceeded|weekly.*limit|usage.*limit|insufficient_quota' "$log_file" 2>/dev/null; then
      MODEL_FALLBACK_WEEKLY_EXHAUSTED=true
      log "model-failover: weekly limit detected for $MODEL_FALLBACK → marking exhausted"
    fi
  fi

  CURRENT_MODEL="$model"
  model_usage_save
  log "model-failover: recorded model=$model elapsed=${elapsed}s exit_code=$exit_code"
}

# Print a one-line status suitable for the dashboard.
model_usage_status_line() {
  model_usage_load
  _model_usage_week_reset_if_needed

  local prem pfall prem_pct pfall_pct threshold
  threshold="$(_model_threshold_seconds)"
  prem="$(_model_remaining_seconds "$MODEL_PRIMARY")"
  pfall="$(_model_remaining_seconds "$MODEL_FALLBACK")"
  prem_pct=$(( prem * 100 / MODEL_SESSION_LIMIT ))
  pfall_pct=$(( pfall * 100 / MODEL_SESSION_LIMIT ))

  local prim_icon fall_icon
  _model_is_available "$MODEL_PRIMARY"  && prim_icon="✅" || prim_icon="⛔"
  _model_is_available "$MODEL_FALLBACK" && fall_icon="✅" || fall_icon="⛔"

  # Colorize percentage: red if ≤threshold, yellow if ≤30%, green otherwise
  local prem_color pfall_color
  if (( prem_pct <= MODEL_SWITCH_THRESHOLD )); then
    prem_color="$C_RED"
  elif (( prem_pct <= 30 )); then
    prem_color="$C_YELLOW"
  else
    prem_color="$C_GREEN"
  fi
  if (( pfall_pct <= MODEL_SWITCH_THRESHOLD )); then
    pfall_color="$C_RED"
  elif (( pfall_pct <= 30 )); then
    pfall_color="$C_YELLOW"
  else
    pfall_color="$C_GREEN"
  fi

  printf '  🤖 %s\n' "$(color "$C_BOLD$C_CYAN" "モデルフェイルオーバー  [週リセット: ${MODEL_USAGE_WEEK_START}]")"
  printf '     %s %-28s %s  残余 %s  %s\n' \
    "$prim_icon" "$MODEL_PRIMARY" \
    "$(color "$prem_color" "$(printf '%3d%%' "$prem_pct")")" \
    "$(printf '%5ds' "$prem")" \
    "$( [[ "${MODEL_PRIMARY_WEEKLY_EXHAUSTED:-false}" == "true" ]] && printf '(週間上限)' )"
  printf '     %s %-28s %s  残余 %s  %s\n' \
    "$fall_icon" "$MODEL_FALLBACK" \
    "$(color "$pfall_color" "$(printf '%3d%%' "$pfall_pct")")" \
    "$(printf '%5ds' "$pfall")" \
    "$( [[ "${MODEL_FALLBACK_WEEKLY_EXHAUSTED:-false}" == "true" ]] && printf '(週間上限)' )"
  printf '     %s %-28s %s\n' \
    "→" "現在の選択:" "$(color "$C_WHITE" "$CURRENT_MODEL")"
}

# Reset usage counters. Args: all | primary | fallback
model_usage_reset() {
  local target="${1:-all}"
  model_usage_load
  case "$target" in
    all)
      MODEL_PRIMARY_SECONDS_USED=0; MODEL_PRIMARY_WEEKLY_EXHAUSTED=false
      MODEL_FALLBACK_SECONDS_USED=0; MODEL_FALLBACK_WEEKLY_EXHAUSTED=false
      CURRENT_MODEL="$MODEL_PRIMARY"
      ;;
    primary)
      MODEL_PRIMARY_SECONDS_USED=0; MODEL_PRIMARY_WEEKLY_EXHAUSTED=false
      ;;
    fallback)
      MODEL_FALLBACK_SECONDS_USED=0; MODEL_FALLBACK_WEEKLY_EXHAUSTED=false
      ;;
    *)
      log "model_usage_reset: unknown target: $target (use all|primary|fallback)"
      return 1
      ;;
  esac
  model_usage_save
  log "model-failover: usage reset: $target"
}

# Mark a model as weekly-exhausted manually.
model_usage_mark_exhausted() {
  local model="$1"
  model_usage_load
  if [[ "$model" == "$MODEL_PRIMARY" ]]; then
    MODEL_PRIMARY_WEEKLY_EXHAUSTED=true
  else
    MODEL_FALLBACK_WEEKLY_EXHAUSTED=true
  fi
  model_usage_save
  log "model-failover: manually marked weekly-exhausted: $model"
}
