#!/usr/bin/env bash
# ============================================================================
# lib/telegram.sh — Fonctions Telegram du pipeline hackathon
# ============================================================================

TELEGRAM_ENABLED="false"

# ── Init Telegram ──────────────────────────────────────────────────────────
# Sets TELEGRAM_ENABLED based on config and token validity.
tg_init() {
  TELEGRAM_ENABLED="false"

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    log "INFO" "Telegram non configuré — notifications désactivées"
    export TELEGRAM_ENABLED
    return 0
  fi

  # Verify bot token is valid
  local check
  check=$(curl -s --max-time 5 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null) || true

  if echo "$check" | jq -e '.ok' &>/dev/null 2>&1; then
    TELEGRAM_ENABLED="true"
    log "INFO" "Telegram activé (Chat ID: ${TELEGRAM_CHAT_ID})"
  else
    log "WARN" "Token Telegram invalide — notifications désactivées"
  fi

  export TELEGRAM_ENABLED
}

# ── Send Telegram message ──────────────────────────────────────────────────
tg_send() {
  local message="$1"

  if [[ "$TELEGRAM_ENABLED" != "true" ]]; then
    return 0
  fi

  curl -s --max-time 10 \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "text=${message}" \
    >/dev/null 2>&1 || true
}

# ── Ask on Telegram and wait for reply ─────────────────────────────────────
# Sends a question and polls for a response within the timeout.
# Prints the response to stdout. Returns 1 on timeout.
tg_ask() {
  local question="$1"
  local timeout="${2:-300}"

  if [[ "$TELEGRAM_ENABLED" != "true" ]]; then
    return 1
  fi

  tg_send "$question"

  local start_time
  start_time=$(date +%s)
  local last_update_id=""

  while true; do
    local now
    now=$(date +%s)
    if (( now - start_time > timeout )); then
      return 1
    fi

    local offset_param=""
    if [[ -n "$last_update_id" ]]; then
      offset_param="&offset=$((last_update_id + 1))"
    fi

    local updates
    updates=$(curl -s --max-time 15 \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=10${offset_param}" \
      2>/dev/null) || continue

    local response
    response=$(echo "$updates" | jq -r '.result[-1].message.text // empty' 2>/dev/null) || true

    if [[ -n "$response" ]]; then
      local update_id
      update_id=$(echo "$updates" | jq -r '.result[-1].update_id // empty' 2>/dev/null) || true
      if [[ -n "$update_id" ]]; then
        last_update_id="$update_id"
      fi
      echo "$response"
      return 0
    fi

    sleep 2
  done
}
