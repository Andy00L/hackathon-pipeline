# .pipeline/ — Runtime State Directory

All files in `.pipeline/` are runtime state, git-ignored.

This directory holds ephemeral coordination state produced and consumed by the
parallel orchestration pipeline during a hackathon run. Nothing here is
authoritative source — it is regenerated each run.

## Contents

| Path | Purpose |
|------|---------|
| `inbox/<role>.jsonl` | Append-only per-role message queues. Each line is a JSON object with at minimum `{from, type, body, ts}`. Roles: `supervisor`, `delivery`, `security`, `quality`. |
| `verdicts.jsonl` | Append-only log of gate verdicts. Each line: `{role, sha, status, timestamp}`. Used by the supervisor to decide phase transitions. |
| `checkpoint/<role>.md` | Written by orchestrators at 80% context usage and by the PreCompact hook. Contains a summary of work-in-progress so the role can resume after context compaction. |
| `dead-letter/` | Messages that could not be parsed or were rejected by the recipient role's schema validation. Kept for debugging; never re-queued automatically. |
| `locks/` | `flock`-backed file locks, one file per locked resource path. Prevents concurrent writes to shared files (e.g., `verdicts.jsonl`). |
| `state.json` | Supervisor cycle counter and last gate state. Reset each run. Schema: `{cycle, last_gate, started_at}`. |
| `mcp.json` | MCP server wiring generated in step 2 of the orchestration redesign. Consumed by Claude Code at session start to connect coordination servers. |
