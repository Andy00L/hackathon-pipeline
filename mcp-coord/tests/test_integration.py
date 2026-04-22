"""Integration test: exercise the MCP server's Coordinator via 3 canned round-trips.

Unlike test_server.py (which tests the Coordinator class directly), this
test exercises the same logical sequence a real orchestrator would use:
  1. post_message  (supervisor → delivery)
  2. claim_next    (delivery claims the message)
  3. record_verdict (delivery records DONE)

All I/O is backed by a temporary .pipeline directory — no network, no
real MCP transport. Must pass in <5s total.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from server import Coordinator


@pytest.fixture
def coord(tmp_path: Path) -> Coordinator:
    """Fresh Coordinator backed by a temp directory."""
    pipeline = tmp_path / ".pipeline"
    pipeline.mkdir()
    (pipeline / "state.json").write_text(
        '{"cycle":0,"last_gate":null,"started_at":null}'
    )
    inbox = pipeline / "inbox"
    inbox.mkdir()
    for role in ("supervisor", "delivery", "security", "quality", "bootstrap"):
        (inbox / f"{role}.jsonl").touch()
    (pipeline / "verdicts.jsonl").touch()
    return Coordinator(pipeline, tmp_path)


def test_three_round_trip_integration(coord: Coordinator):
    """Simulate supervisor→delivery→record_verdict, the core happy path."""

    # ── Round-trip 1: post_message ────────────────────────────────────────
    post_result = coord.post_message(
        from_role="supervisor",
        to_role="delivery",
        topic="implement",
        payload='{"task":"build auth module","priority":"high"}',
        sha="abc123def456",
    )
    assert post_result["status"] == "posted", f"post_message failed: {post_result}"
    assert "message_id" in post_result
    assert post_result["bytes"] > 0
    mid = post_result["message_id"]

    # ── Round-trip 2: claim_next ───────────────────────────────────��──────
    claim_result = coord.claim_next("delivery")
    assert claim_result["from"] == "supervisor"
    assert claim_result["to"] == "delivery"
    assert claim_result["topic"] == "implement"
    assert claim_result["sha"] == "abc123def456"
    assert claim_result["message_id"] == mid
    payload = json.loads(claim_result["payload"])
    assert payload["task"] == "build auth module"

    # Inbox should now be empty
    empty = coord.claim_next("delivery")
    assert empty["status"] == "empty"

    # ── Round-trip 3: record_verdict ─────��────────────────────────────────
    verdict_result = coord.record_verdict(
        role="delivery",
        status="DONE",
        sha="abc123def456",
        evidence="all tests pass, 95% coverage",
        findings="",
    )
    assert verdict_result["status"] == "recorded"
    assert "id" in verdict_result

    # Verify the verdict landed on disk
    verdicts_path = coord.pipeline_dir / "verdicts.jsonl"
    lines = [
        json.loads(l)
        for l in verdicts_path.read_text().strip().split("\n")
        if l.strip()
    ]
    assert len(lines) == 1
    assert lines[0]["role"] == "delivery"
    assert lines[0]["status"] == "DONE"
    assert lines[0]["sha"] == "abc123def456"
    assert lines[0]["evidence"] == "all tests pass, 95% coverage"
