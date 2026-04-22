#!/usr/bin/env bash
# posttooluse-fanout.sh — PostToolUse hook for Edit|Write|MultiEdit
#
# Schema verified against: https://code.claude.com/docs/en/hooks
# PostToolUse output (optional): {"decision":"block","reason":"..."}
# We never block — this is observational fanout only. Exit 0 always.
set -euo pipefail

PIPELINE_DIR="${CLAUDE_PROJECT_DIR:-.}/.pipeline"
FANOUT_STATE="${PIPELINE_DIR}/last-fanout.txt"
CLIENT_HELPER="${CLAUDE_PROJECT_DIR:-$(pwd)}/mcp-coord/client_helper.py"
HOOKS_LOG="${PIPELINE_DIR}/hooks.log"
mkdir -p "$PIPELINE_DIR"

# Read stdin
INPUT="$(cat)"

# Extract file path from tool_input
if ! JQ_BIN="$(command -v jq 2>/dev/null)"; then
  echo "$(date -Iseconds) FANOUT-SKIP jq not found" >> "$HOOKS_LOG"
  exit 0
fi

FILE_PATH="$("$JQ_BIN" -r '.tool_input.file_path // empty' <<< "$INPUT" 2>/dev/null)" || {
  exit 0
}

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Only fan out for paths inside src/, tests/, or buildscript files
RELEVANT=false
case "$FILE_PATH" in
  */src/*|*/tests/*|*/test/*)
    RELEVANT=true
    ;;
  *Makefile*|*Dockerfile*|*docker-compose*|*.mk|*build.sh|*CMakeLists*)
    RELEVANT=true
    ;;
  *package.json|*setup.py|*setup.cfg|*pyproject.toml|*Cargo.toml|*go.mod)
    RELEVANT=true
    ;;
esac

if [[ "$RELEVANT" != "true" ]]; then
  exit 0
fi

# Debounce: skip if last fanout for this SHA was <30s ago
CURRENT_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
NOW="$(date +%s)"

if [[ -f "$FANOUT_STATE" ]]; then
  LAST_LINE="$(tail -1 "$FANOUT_STATE" 2>/dev/null || echo "")"
  LAST_SHA="$(echo "$LAST_LINE" | cut -d' ' -f1)"
  LAST_TS="$(echo "$LAST_LINE" | cut -d' ' -f2)"
  if [[ "$LAST_SHA" == "$CURRENT_SHA" && -n "$LAST_TS" ]]; then
    ELAPSED=$(( NOW - LAST_TS ))
    if [[ "$ELAPSED" -lt 30 ]]; then
      echo "$(date -Iseconds) FANOUT-DEBOUNCE sha=$CURRENT_SHA elapsed=${ELAPSED}s" >> "$HOOKS_LOG"
      exit 0
    fi
  fi
fi

# Record this fanout
echo "$CURRENT_SHA $NOW" > "$FANOUT_STATE"

# Post review_diff to security inbox
if [[ -x "$CLIENT_HELPER" ]] || command -v python3 &>/dev/null; then
  python3 "$CLIENT_HELPER" post_message \
    --from delivery --to security --topic review_diff \
    --sha "$CURRENT_SHA" --payload '{"auto":true}' 2>>"$HOOKS_LOG" || true

  # Post new_feature to quality inbox
  python3 "$CLIENT_HELPER" post_message \
    --from delivery --to quality --topic new_feature \
    --sha "$CURRENT_SHA" --payload '{"auto":true}' 2>>"$HOOKS_LOG" || true

  echo "$(date -Iseconds) FANOUT sha=$CURRENT_SHA file=$FILE_PATH" >> "$HOOKS_LOG"
else
  echo "$(date -Iseconds) FANOUT-SKIP python3 not found" >> "$HOOKS_LOG"
fi

exit 0
