#!/usr/bin/env bash
# pretooluse-safeguard.sh — PreToolUse hook for Bash tool safety
#
# Schema verified against: https://code.claude.com/docs/en/hooks
# Output format (PreToolUse):
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#    "permissionDecision":"allow|deny",
#    "permissionDecisionReason":"..."}}
# Exit code: always 0 (decision carried in JSON).
set -euo pipefail

HOOKS_LOG="${CLAUDE_PROJECT_DIR:-.}/.pipeline/hooks.log"
mkdir -p "$(dirname "$HOOKS_LOG")"

emit_decision() {
  local decision="$1"
  local reason="${2:-}"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$decision" "$reason"
}

# Read all of stdin
INPUT="$(cat)"

# Parse the command from tool_input via jq
if ! JQ_BIN="$(command -v jq 2>/dev/null)"; then
  echo "$(date -Iseconds) DENY jq not found — failing closed for safety" >> "$HOOKS_LOG"
  emit_decision "deny" "jq not found — failing closed for safety"
  exit 0
fi

CMD="$("$JQ_BIN" -r '.tool_input.command // empty' <<< "$INPUT" 2>/dev/null)" || {
  # stdin was not valid JSON — fail open (non-Bash tool call or garbled input)
  echo "$(date -Iseconds) ALLOW non-JSON input (fail-open)" >> "$HOOKS_LOG"
  emit_decision "allow" "Non-JSON input — fail-open"
  exit 0
}

if [[ -z "$CMD" ]]; then
  echo "$(date -Iseconds) ALLOW empty command" >> "$HOOKS_LOG"
  emit_decision "allow" "Empty or missing command"
  exit 0
fi

# ── Dangerous patterns (case-insensitive, anchored where appropriate) ──────
DANGEROUS_PATTERNS=(
  'rm\s+-rf\s+[/~]'
  'git\s+push\s+--force'
  'git\s+reset\s+--hard'
  'chmod\s+777'
  '>\s*/dev/sd'
  'mkfs\.'
  'dd\s+if='
  'curl\s+.*\|\s*(bash|sh)'
  'wget\s+.*-O-\s*\|\s*(bash|sh)'
  'history\s+-c'
  'git\s+filter-branch'
  'git\s+push\s+--mirror'
)

# Build combined regex
COMBINED=""
for pat in "${DANGEROUS_PATTERNS[@]}"; do
  if [[ -n "$COMBINED" ]]; then
    COMBINED="${COMBINED}|${pat}"
  else
    COMBINED="$pat"
  fi
done

if echo "$CMD" | grep -qiE "($COMBINED)"; then
  echo "$(date -Iseconds) DENY dangerous pattern matched: $CMD" >> "$HOOKS_LOG"
  emit_decision "deny" "Commande bloquee par safeguard"
  exit 0
fi

# ── Windows filesystem access ──────────────────────────────────────────────
if echo "$CMD" | grep -qE '/mnt/[a-z]/'; then
  echo "$(date -Iseconds) DENY Windows filesystem access: $CMD" >> "$HOOKS_LOG"
  emit_decision "deny" "Acces Windows filesystem bloque"
  exit 0
fi

echo "$(date -Iseconds) ALLOW $CMD" >> "$HOOKS_LOG"
emit_decision "allow" ""
exit 0
