#!/usr/bin/env python3
"""
client_helper.py — CLI wrapper for posting messages to .pipeline inbox files.

Shares the same message format as mcp-coord/server.py Coordinator.post_message
so hooks can communicate without spinning up a full Claude process or MCP server.

If the MCP server is down, messages still land in inbox files (file-based,
server picks them up on next claim_next).

Usage:
    python3 client_helper.py post_message \
        --from delivery --to security --topic review_diff \
        --sha "abc123" --payload '{"auto":true}'
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

# ── Import atomic helpers from server.py if available ──────────────────────
# Fall back to standalone implementation if import fails (e.g. running
# outside the project or server.py has unresolvable deps).

_USE_SERVER_ULID = False
try:
    # Add parent dir so we can import server module
    _this_dir = Path(__file__).resolve().parent
    if str(_this_dir) not in sys.path:
        sys.path.insert(0, str(_this_dir))
    from server import generate_ulid, VALID_ROLES, ALLOWED_TOPICS
    _USE_SERVER_ULID = True
except ImportError:
    # Standalone fallback
    VALID_ROLES = frozenset({"supervisor", "delivery", "security", "quality", "bootstrap"})
    ALLOWED_TOPICS = frozenset({
        "implement", "review_diff", "new_feature", "sec_ok", "finding",
        "regression", "fix_applied", "blocked", "veto", "veto_last_commit",
        "lock_conflict", "context_pressure", "gate_security", "gate_quality",
        "ping", "shutdown", "suggest_edit", "split_request", "stuck", "conflict",
    })

    _ULID_CHARS = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    def generate_ulid() -> str:
        ts_ms = int(time.time() * 1000)
        ts_part: list[str] = []
        for _ in range(10):
            ts_part.append(_ULID_CHARS[ts_ms & 0x1F])
            ts_ms >>= 5
        ts_part.reverse()
        rand_val = int.from_bytes(os.urandom(10), "big")
        rand_part: list[str] = []
        for _ in range(16):
            rand_part.append(_ULID_CHARS[rand_val & 0x1F])
            rand_val >>= 5
        rand_part.reverse()
        return "".join(ts_part) + "".join(rand_part)


def atomic_append(path: str, line: str) -> int:
    """Append a single line atomically: O_APPEND + fsync, no partial lines.

    Same semantics as Coordinator._atomic_append in server.py.
    """
    data = (line if line.endswith("\n") else line + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        n = os.write(fd, data)
        os.fsync(fd)
        return n
    finally:
        os.close(fd)


def find_pipeline_dir() -> Path:
    """Locate .pipeline dir: CLAUDE_PROJECT_DIR env, then walk up from cwd."""
    proj = os.environ.get("CLAUDE_PROJECT_DIR")
    if proj:
        p = Path(proj) / ".pipeline"
        if p.is_dir():
            return p
        p.mkdir(parents=True, exist_ok=True)
        return p
    # Walk up from cwd
    cur = Path.cwd()
    for d in [cur] + list(cur.parents):
        candidate = d / ".pipeline"
        if candidate.is_dir():
            return candidate
    # Default: create under cwd
    p = cur / ".pipeline"
    p.mkdir(parents=True, exist_ok=True)
    return p


def post_message(
    from_role: str,
    to_role: str,
    topic: str,
    payload: str,
    sha: str = "",
    pipeline_dir: Path | None = None,
) -> dict:
    """Post a message to a role's inbox, same format as server.py."""
    if from_role not in VALID_ROLES:
        return {"status": "error", "error": f"invalid from_role: {from_role!r}"}
    if to_role not in VALID_ROLES:
        return {"status": "error", "error": f"invalid to_role: {to_role!r}"}
    if topic not in ALLOWED_TOPICS:
        return {"status": "error", "error": f"unknown topic: {topic!r}"}

    if pipeline_dir is None:
        pipeline_dir = find_pipeline_dir()

    inbox_dir = pipeline_dir / "inbox"
    inbox_dir.mkdir(parents=True, exist_ok=True)

    message_id = generate_ulid()
    msg: dict = {
        "message_id": message_id,
        "from": from_role,
        "to": to_role,
        "topic": topic,
        "payload": payload,
        "ts": time.time(),
        "seq": 0,  # seq=0 marks client-helper origin; server assigns real seqs
    }
    if sha:
        msg["sha"] = sha

    inbox_path = str(inbox_dir / f"{to_role}.jsonl")
    line = json.dumps(msg, separators=(",", ":"))
    nbytes = atomic_append(inbox_path, line)
    return {"status": "posted", "message_id": message_id, "bytes": nbytes}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="CLI helper for pipeline inbox messaging"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    pm = sub.add_parser("post_message", help="Post a message to a role inbox")
    pm.add_argument("--from", dest="from_role", required=True, help="Sender role")
    pm.add_argument("--to", dest="to_role", required=True, help="Recipient role")
    pm.add_argument("--topic", required=True, help="Message topic")
    pm.add_argument("--payload", default="{}", help="JSON payload string")
    pm.add_argument("--sha", default="", help="Git SHA reference")
    pm.add_argument("--pipeline-dir", default=None, help="Override .pipeline dir path")

    args = parser.parse_args()

    if args.command == "post_message":
        pd = Path(args.pipeline_dir) if args.pipeline_dir else None
        result = post_message(
            from_role=args.from_role,
            to_role=args.to_role,
            topic=args.topic,
            payload=args.payload,
            sha=args.sha,
            pipeline_dir=pd,
        )
        print(json.dumps(result))
        return 0 if result["status"] == "posted" else 1

    return 1


if __name__ == "__main__":
    sys.exit(main())
