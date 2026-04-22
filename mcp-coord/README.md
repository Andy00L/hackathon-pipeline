# MCP Coordination Server

Stdio MCP server for inter-orchestrator communication in the parallel pipeline.

## Setup

```bash
cd mcp-coord
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Run standalone

```bash
python3 mcp-coord/server.py          # stdio: reads JSON-RPC from stdin
python3 mcp-coord/server.py < /dev/null  # exits cleanly on EOF
```

## Run tests

```bash
source mcp-coord/.venv/bin/activate
python3 -m pytest mcp-coord/tests -q
```

## Tools

| Tool | Description |
|------|-------------|
| `post_message` | Post a typed message between orchestrator roles |
| `claim_next` | Atomically pop the oldest unclaimed message from a role's inbox |
| `record_verdict` | Record a gate verdict (delivery/security/quality) |
| `request_gate` | Read the supervisor's cached gate decision |
| `get_latest_diff` | Get git diff from a ref to HEAD (truncated at 64KB) |
| `acquire_file_lock` | Acquire an exclusive file lock with TTL |
| `release_file_lock` | Release a previously acquired file lock |
| `heartbeat` | Write a heartbeat timestamp for watchdog monitoring |

## MCP config

Point Claude Code at `.pipeline/mcp.json` via `--mcp-config`.
