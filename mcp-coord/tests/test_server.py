"""Test suite for the MCP coordination server.

All tests use tmp_path fixtures — no network, no real .pipeline dir.
Must pass in <5s total.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

# We import the Coordinator class directly — tests exercise the core logic
# without needing the MCP transport layer.
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from server import Coordinator, generate_ulid


@pytest.fixture
def coord(tmp_path: Path) -> Coordinator:
    """Fresh Coordinator backed by a temp directory."""
    pipeline = tmp_path / ".pipeline"
    pipeline.mkdir()
    # Seed state.json
    (pipeline / "state.json").write_text('{"cycle":0,"last_gate":null,"started_at":null}')
    # Create inbox files for all roles
    inbox = pipeline / "inbox"
    inbox.mkdir()
    for role in ("supervisor", "delivery", "security", "quality", "bootstrap"):
        (inbox / f"{role}.jsonl").touch()
    (pipeline / "verdicts.jsonl").touch()
    return Coordinator(pipeline, tmp_path)


# ═══════════════════════════════════════════════════════════════════════════
# 1. post_message + claim_next roundtrip
# ═══════════════════════════════════════════════════════════════════════════

def test_post_and_claim_roundtrip(coord: Coordinator):
    result = coord.post_message(
        from_role="supervisor",
        to_role="delivery",
        topic="implement",
        payload="build the auth module",
        sha="abc123",
    )
    assert result["status"] == "posted"
    assert "message_id" in result
    assert result["bytes"] > 0

    claimed = coord.claim_next("delivery")
    assert claimed["from"] == "supervisor"
    assert claimed["to"] == "delivery"
    assert claimed["topic"] == "implement"
    assert claimed["payload"] == "build the auth module"
    assert claimed["sha"] == "abc123"
    assert claimed["message_id"] == result["message_id"]

    # Inbox should now be empty
    empty = coord.claim_next("delivery")
    assert empty["status"] == "empty"


# ═══════════════════════════════════════════════════════════════════════════
# 2. Duplicate message_id dedup
# ═══════════════════════════════════════════════════════════════════════════

def test_duplicate_message_id_dedup(coord: Coordinator):
    mid = generate_ulid()
    r1 = coord.post_message("supervisor", "delivery", "ping", "hello", message_id=mid)
    assert r1["status"] == "posted"

    r2 = coord.post_message("supervisor", "delivery", "ping", "hello again", message_id=mid)
    assert r2["status"] == "duplicate"
    assert r2["message_id"] == mid

    # Only one message should be in inbox
    claimed = coord.claim_next("delivery")
    assert claimed["payload"] == "hello"
    assert coord.claim_next("delivery")["status"] == "empty"


# ═══════════════════════════════════════════════════════════════════════════
# 3. claim_next on empty inbox
# ═══════════════════════════════════════════════════════════════════════════

def test_claim_next_empty(coord: Coordinator):
    result = coord.claim_next("supervisor")
    assert result["status"] == "empty"


# ═══════════════════════════════════════════════════════════════════════════
# 4. record_verdict append + read-back ordering
# ═══════════════════════════════════════════════════════════════════════════

def test_record_verdict_ordering(coord: Coordinator):
    r1 = coord.record_verdict("security", "PASS", "aaa111")
    assert r1["status"] == "recorded"

    r2 = coord.record_verdict("quality", "READY", "aaa111", findings="looks good")
    assert r2["status"] == "recorded"

    r3 = coord.record_verdict("delivery", "DONE", "aaa111", evidence="tests pass")
    assert r3["status"] == "recorded"

    # Read back and verify ordering by seq
    verdicts_path = coord.pipeline_dir / "verdicts.jsonl"
    lines = [json.loads(l) for l in verdicts_path.read_text().strip().split("\n") if l.strip()]
    assert len(lines) == 3
    assert lines[0]["role"] == "security"
    assert lines[1]["role"] == "quality"
    assert lines[1]["findings"] == "looks good"
    assert lines[2]["role"] == "delivery"
    assert lines[2]["evidence"] == "tests pass"
    # Monotonic seq
    assert lines[0]["seq"] < lines[1]["seq"] < lines[2]["seq"]


# ═══════════════════════════════════════════════════════════════════════════
# 5. Invalid role/topic rejected
# ═══════════════════════════════════════════════════════════════════════════

def test_invalid_role_rejected(coord: Coordinator):
    r = coord.post_message("securty", "delivery", "ping", "x")
    assert r["status"] == "error"
    assert "invalid from_role" in r["error"]

    r2 = coord.claim_next("securty")
    assert r2["status"] == "error"
    assert "invalid role" in r2["error"]


def test_invalid_topic_rejected(coord: Coordinator):
    r = coord.post_message("supervisor", "delivery", "unknown_topic", "x")
    assert r["status"] == "error"
    assert "unknown topic" in r["error"]


def test_invalid_verdict_rejected(coord: Coordinator):
    r = coord.record_verdict("security", "INVALID_STATUS", "abc")
    assert r["status"] == "error"
    assert "invalid status" in r["error"]

    r2 = coord.record_verdict("supervisor", "PASS", "abc")
    assert r2["status"] == "error"
    assert "invalid role" in r2["error"]


# ═══════════════════════════════════════════════════════════════════════════
# 6. acquire_file_lock contention + TTL expiry
# ═══════════════════════════════════════════════════════════════════════════

def test_lock_contention_and_ttl(coord: Coordinator):
    # Owner A acquires
    r1 = coord.acquire_file_lock("src/main.py", "delivery", ttl_seconds=1)
    assert r1["status"] == "acquired"
    token_a = r1["token"]

    # Owner B is blocked
    r2 = coord.acquire_file_lock("src/main.py", "security")
    assert r2["status"] == "held"
    assert r2["held_by"] == "delivery"
    assert r2["expires_in"] >= 0

    # Wait for TTL to expire
    time.sleep(1.5)

    # Owner B can now take over
    r3 = coord.acquire_file_lock("src/main.py", "security", ttl_seconds=120)
    assert r3["status"] == "acquired"

    # Verify takeover was audited
    audit_path = coord.pipeline_dir / "locks" / "audit.jsonl"
    assert audit_path.exists()
    audit_lines = [json.loads(l) for l in audit_path.read_text().strip().split("\n") if l.strip()]
    takeovers = [e for e in audit_lines if e["event"] == "takeover"]
    assert len(takeovers) >= 1
    assert takeovers[0]["old_owner"] == "delivery"
    assert takeovers[0]["new_owner"] == "security"


# ═══════════════════════════════════════════════════════════════════════════
# 7. acquire_file_lock rejects dangerous paths
# ═══════════════════════════════════════════════════════════════════════════

def test_lock_rejects_bad_paths(coord: Coordinator):
    # Path with ..
    r1 = coord.acquire_file_lock("../../../etc/passwd", "delivery")
    assert r1["status"] == "error"
    assert ".." in r1["error"]

    # Absolute path outside repo
    r2 = coord.acquire_file_lock("/etc/passwd", "delivery")
    assert r2["status"] == "error"
    assert "inside the repo" in r2["error"]


# ═══════════════════════════════════════════════════════════════════════════
# 8. release_file_lock with wrong token rejected
# ═══════════════════════════════════════════════════════════════════════════

def test_release_wrong_token_rejected(coord: Coordinator):
    r = coord.acquire_file_lock("README.md", "delivery")
    assert r["status"] == "acquired"
    real_token = r["token"]

    # Wrong token
    r2 = coord.release_file_lock("README.md", "BOGUS_TOKEN_12345")
    assert r2["status"] == "rejected"
    assert r2["held_by"] == "delivery"

    # Correct token
    r3 = coord.release_file_lock("README.md", real_token)
    assert r3["status"] == "released"

    # Verify release was audited
    audit_path = coord.pipeline_dir / "locks" / "audit.jsonl"
    audit_lines = [json.loads(l) for l in audit_path.read_text().strip().split("\n") if l.strip()]
    releases = [e for e in audit_lines if e["event"] == "release"]
    assert len(releases) == 1
    assert releases[0]["token"] == real_token


# ═══════════════════════════════════════════════════════════════════════════
# 9. Malformed JSON in inbox → dead-letter
# ═══════════════════════════════════════════════════════════════════════════

def test_malformed_json_dead_lettered(coord: Coordinator):
    # Write a non-JSON line directly to the inbox
    inbox_path = coord.pipeline_dir / "inbox" / "delivery.jsonl"
    inbox_path.write_text("THIS IS NOT JSON\n")

    result = coord.claim_next("delivery")
    assert result["status"] == "error"
    assert "dead-letter" in result["error"]

    # Verify dead-letter was written
    dl_dir = coord.pipeline_dir / "dead-letter"
    dl_files = list(dl_dir.glob("*.json"))
    assert len(dl_files) >= 1
    dl_content = json.loads(dl_files[0].read_text())
    assert "THIS IS NOT JSON" in dl_content["raw"]

    # Inbox should now be empty (malformed line was consumed)
    assert coord.claim_next("delivery")["status"] == "empty"


# ═══════════════════════════════════════════════════════════════════════════
# 10. get_latest_diff on bogus ref → no crash
# ═══════════════════════════════════════════════════════════════════════════

def test_get_latest_diff_bogus_ref(coord: Coordinator):
    # Initialize a git repo in the temp dir
    subprocess.run(["git", "init"], cwd=str(coord.repo_root), capture_output=True)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"],
        cwd=str(coord.repo_root),
        capture_output=True,
        env={**os.environ, "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "t@t",
             "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "t@t"},
    )

    result = coord.get_latest_diff("nonexistent_ref_abc123")
    assert result["status"] == "no_ref"
    assert result["ref"] == "nonexistent_ref_abc123"


def test_get_latest_diff_valid_ref(coord: Coordinator):
    """Verify diff works against a real ref."""
    repo = coord.repo_root
    env = {**os.environ, "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "t@t"}
    subprocess.run(["git", "init"], cwd=str(repo), capture_output=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "init"], cwd=str(repo),
                   capture_output=True, env=env)

    # Get the initial commit hash
    r = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(repo), capture_output=True, text=True)
    initial = r.stdout.strip()

    # Create a file and commit
    (repo / "hello.txt").write_text("hello world\n")
    subprocess.run(["git", "add", "hello.txt"], cwd=str(repo), capture_output=True)
    subprocess.run(["git", "commit", "-m", "add hello"], cwd=str(repo), capture_output=True, env=env)

    result = coord.get_latest_diff(initial)
    assert "changed_files" in result
    assert "hello.txt" in result["changed_files"]
    assert "hello world" in result["diff"]


# ═══════════════════════════════════════════════════════════════════════════
# 11. Threading: two threads race for the same lock
# ═══════════════════════════════════════════════════════════════════════════

def test_lock_threading_contention(coord: Coordinator):
    results = []

    def try_acquire(owner: str):
        r = coord.acquire_file_lock("shared/resource.txt", owner, ttl_seconds=60)
        results.append((owner, r))

    with ThreadPoolExecutor(max_workers=2) as pool:
        f1 = pool.submit(try_acquire, "delivery")
        f2 = pool.submit(try_acquire, "security")
        f1.result()
        f2.result()

    statuses = {r["status"] for _, r in results}
    assert "acquired" in statuses
    # The other thread gets "held" (or also "acquired" if timing allows —
    # O_EXCL guarantees at most one wins atomically)
    acquired_count = sum(1 for _, r in results if r["status"] == "acquired")
    held_count = sum(1 for _, r in results if r["status"] == "held")
    assert acquired_count == 1
    assert held_count == 1


# ═══════════════════════════════════════════════════════════════════════════
# 12. request_gate reads state.json
# ═══════════════════════════════════════════════════════════════════════════

def test_request_gate_no_decision(coord: Coordinator):
    result = coord.request_gate("gate_security")
    assert result["status"] == "no_decision"


def test_request_gate_with_decision(coord: Coordinator):
    state_path = coord.pipeline_dir / "state.json"
    now = time.time()
    state = {
        "cycle": 1,
        "last_gate": "gate_security",
        "last_gate_decision": "PASS",
        "last_gate_ts": now,
        "started_at": now - 100,
    }
    state_path.write_text(json.dumps(state))

    result = coord.request_gate("gate_security")
    assert result["status"] == "ok"
    assert result["decision"] == "PASS"


def test_request_gate_stale(coord: Coordinator):
    state_path = coord.pipeline_dir / "state.json"
    state = {
        "cycle": 1,
        "last_gate": "gate_quality",
        "last_gate_decision": "READY",
        "last_gate_ts": time.time() - 600,  # 10 min ago
    }
    state_path.write_text(json.dumps(state))

    result = coord.request_gate("gate_quality")
    assert result["status"] == "stale"


def test_request_gate_invalid(coord: Coordinator):
    result = coord.request_gate("gate_bogus")
    assert result["status"] == "error"


# ═══════════════════════════════════════════════════════════════════════════
# 13. heartbeat writes timestamp
# ═══════════════════════════════════════════════════════════════════════════

def test_heartbeat(coord: Coordinator):
    result = coord.heartbeat("delivery")
    assert result["status"] == "ok"
    assert "ts" in result

    hb_path = coord.pipeline_dir / "heartbeat" / "delivery.txt"
    assert hb_path.exists()
    ts = int(hb_path.read_text().strip())
    assert abs(ts - time.time()) < 5


def test_heartbeat_invalid_role(coord: Coordinator):
    result = coord.heartbeat("bogus")
    assert result["status"] == "error"


# ═══════════════════════════════════════════════════════════════════════════
# 14. ULID generation sanity
# ═══════════════════════════════════════════════════════════════════════════

def test_ulid_uniqueness():
    ids = {generate_ulid() for _ in range(100)}
    assert len(ids) == 100  # All unique


def test_ulid_length():
    u = generate_ulid()
    assert len(u) == 26


# ═══════════════════════════════════════════════════════════════════════════
# 15. Multi-message claim ordering
# ═══════════════════════════════════════════════════════════════════════════

def test_claim_fifo_ordering(coord: Coordinator):
    """Messages are claimed in FIFO order."""
    for i in range(5):
        coord.post_message("supervisor", "quality", "ping", f"msg-{i}")

    for i in range(5):
        msg = coord.claim_next("quality")
        assert msg["payload"] == f"msg-{i}"

    assert coord.claim_next("quality")["status"] == "empty"
