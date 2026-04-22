#!/usr/bin/env bash
# precompact-checkpoint.sh — PreCompact hook for writing role checkpoints
#
# Schema verified against: https://code.claude.com/docs/en/hooks
# PreCompact does NOT use hookSpecificOutput. To allow compaction: exit 0
# with no JSON. To block: exit 2 or emit {"decision":"block","reason":"..."}.
# We never block — this is purely observational.
set -euo pipefail

PIPELINE_DIR="${CLAUDE_PROJECT_DIR:-.}/.pipeline"
CHECKPOINT_DIR="${PIPELINE_DIR}/checkpoint"
mkdir -p "$CHECKPOINT_DIR"

# Determine role from CLAUDE_SESSION_ID env var.
# Orchestrator sets this to one of: supervisor, delivery, security, quality.
ROLE="${CLAUDE_SESSION_ID:-}"
if [[ -z "$ROLE" ]]; then
  ROLE="unknown-$$"
fi

TIMESTAMP="$(date -Iseconds)"
SHA="$(git rev-parse HEAD 2>/dev/null || echo none)"

# Count inbox items safely
INBOX_FILE="${PIPELINE_DIR}/inbox/${ROLE}.jsonl"
if [[ -f "$INBOX_FILE" ]]; then
  INBOX_COUNT="$(wc -l < "$INBOX_FILE")"
else
  INBOX_COUNT="0"
fi

# Last 5 verdicts
VERDICTS_FILE="${PIPELINE_DIR}/verdicts.jsonl"
if [[ -f "$VERDICTS_FILE" ]]; then
  LAST_VERDICTS="$(tail -5 "$VERDICTS_FILE")"
else
  LAST_VERDICTS="(none)"
fi

# Write to temp file, then atomic rename
DEST="${CHECKPOINT_DIR}/${ROLE}.md"
TMP_FILE="$(mktemp "${CHECKPOINT_DIR}/.tmp-${ROLE}.XXXXXX")"

cat > "$TMP_FILE" << EOF
# Checkpoint — ${ROLE} — ${TIMESTAMP}

## Last SHA seen
${SHA}

## Open inbox items
${INBOX_COUNT} messages pending

## Last 5 verdicts recorded
${LAST_VERDICTS}

## Reason
Auto-compaction about to run
EOF

mv "$TMP_FILE" "$DEST"

# Exit 0 with no JSON output — allow compaction to proceed
exit 0
