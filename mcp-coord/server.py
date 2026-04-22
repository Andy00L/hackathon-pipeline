#!/usr/bin/env python3
"""
MCP stdio coordination server for parallel pipeline orchestration.

Exposes 8 tools for inter-orchestrator communication:
  post_message, claim_next, record_verdict, request_gate,
  get_latest_diff, acquire_file_lock, release_file_lock, heartbeat

Transport: JSON-RPC 2.0 over stdin/stdout (MCP stdio).
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# ─── Platform gate ─────────────────────────────────────────────────────────
try:
    import fcntl
except ImportError:
    print(
        "FATAL: fcntl is unavailable. This pipeline requires Linux/WSL2.",
        file=sys.stderr,
    )
    sys.exit(1)

from mcp.server.fastmcp import FastMCP

# ═══════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════

VALID_ROLES = frozenset({"supervisor", "delivery", "security", "quality", "bootstrap"})

ALLOWED_TOPICS = frozenset({
    "implement", "review_diff", "new_feature", "sec_ok", "finding",
    "regression", "fix_applied", "blocked", "veto", "veto_last_commit",
    "lock_conflict", "context_pressure", "gate_security", "gate_quality",
    "ping", "shutdown", "suggest_edit", "split_request", "stuck", "conflict",
})

VERDICT_STATUSES: dict[str, frozenset[str]] = {
    "delivery": frozenset({"IN_PROGRESS", "BUILT", "DONE", "BLOCKED"}),
    "security": frozenset({"PASS", "FAIL", "STALE"}),
    "quality":  frozenset({"READY", "READY_WITH_FIXES", "NOT_READY", "STALE"}),
}

VALID_GATES = frozenset({"gate_security", "gate_quality", "gate_terminate"})

ULID_CHARS = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
MAX_DIFF_BYTES = 64 * 1024
STALE_GATE_SECONDS = 300  # 5 minutes
CLAIM_CHUNK = 65536


# ═══════════════════════════════════════════════════════════════════════════
# ULID generator (stdlib-only, no external dep)
# ═══════════════════════════════════════════════════════════════════════════

def generate_ulid() -> str:
    ts_ms = int(time.time() * 1000)
    ts_part: list[str] = []
    for _ in range(10):
        ts_part.append(ULID_CHARS[ts_ms & 0x1F])
        ts_ms >>= 5
    ts_part.reverse()
    rand_val = int.from_bytes(os.urandom(10), "big")
    rand_part: list[str] = []
    for _ in range(16):
        rand_part.append(ULID_CHARS[rand_val & 0x1F])
        rand_val >>= 5
    rand_part.reverse()
    return "".join(ts_part) + "".join(rand_part)


# ═══════════════════════════════════════════════════════════════════════════
# Coordinator — all file-based coordination logic, transport-agnostic
# ═══════════════════════════════════════════════════════════════════════════

class Coordinator:
    """Core coordination logic backed by the .pipeline/ filesystem layout."""

    def __init__(self, pipeline_dir: Path, repo_root: Path) -> None:
        self.pipeline_dir = Path(pipeline_dir).resolve()
        self.repo_root = Path(repo_root).resolve()
        self._dedup_cache: dict[str, float] = {}
        self._logger = logging.getLogger("mcp-coord")
        self._ensure_dirs()
        self._load_dedup_cache()

    # ── directory bootstrap ────────────────────────────────────────────

    def _ensure_dirs(self) -> None:
        for sub in ("inbox", "dead-letter", "locks", "heartbeat"):
            (self.pipeline_dir / sub).mkdir(parents=True, exist_ok=True)

    # ── atomic I/O helpers ─────────────────────────────────────────────

    def _atomic_append(self, path: str, line: str) -> int:
        """Append a single line atomically: one write() + fsync, no partial lines."""
        data = (line if line.endswith("\n") else line + "\n").encode("utf-8")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        try:
            n = os.write(fd, data)
            os.fsync(fd)
            return n
        finally:
            os.close(fd)

    def _atomic_write_json(self, path: Path, obj: object) -> None:
        """Write JSON atomically via tmp-fsync-rename."""
        tmp_fd, tmp_path = tempfile.mkstemp(
            dir=str(path.parent), suffix=".tmp"
        )
        try:
            with os.fdopen(tmp_fd, "w") as f:
                json.dump(obj, f, separators=(",", ":"))
                f.flush()
                os.fsync(f.fileno())
            os.rename(tmp_path, str(path))
        except BaseException:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

    # ── dedup index ────────────────────────────────────────────────────

    def _dedup_path(self) -> Path:
        return self.pipeline_dir / "inbox" / "_dedup.jsonl"

    def _load_dedup_cache(self) -> None:
        cutoff = time.time() - 86400
        path = self._dedup_path()
        if not path.exists():
            return
        try:
            with open(path, "r") as f:
                for raw in f:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        entry = json.loads(raw)
                        if entry.get("ts", 0) > cutoff:
                            self._dedup_cache[entry["message_id"]] = entry["ts"]
                    except (json.JSONDecodeError, KeyError):
                        pass
        except FileNotFoundError:
            pass

    def _record_dedup(self, message_id: str) -> None:
        ts = time.time()
        self._dedup_cache[message_id] = ts
        line = json.dumps({"message_id": message_id, "ts": ts}, separators=(",", ":"))
        self._atomic_append(str(self._dedup_path()), line)

    def _is_duplicate(self, message_id: str) -> bool:
        ts = self._dedup_cache.get(message_id)
        if ts is not None:
            return ts > time.time() - 86400
        return False

    # ── monotonic sequence counter (persisted in state.json) ───────────

    def _next_seq(self) -> int:
        state_path = self.pipeline_dir / "state.json"
        lock_path = self.pipeline_dir / "inbox" / "_seq.lock"
        with open(str(lock_path), "w") as lf:
            fcntl.flock(lf, fcntl.LOCK_EX)
            try:
                with open(str(state_path), "r") as sf:
                    state = json.load(sf)
            except (FileNotFoundError, json.JSONDecodeError):
                state = {"cycle": 0, "last_gate": None, "started_at": None}
            seq = state.get("_seq", 0) + 1
            state["_seq"] = seq
            self._atomic_write_json(state_path, state)
            fcntl.flock(lf, fcntl.LOCK_UN)
        return seq

    # ── dead-letter ────────────────────────────────────────────────────

    def _dead_letter(self, raw: bytes | str, reason: str = "") -> None:
        dl_dir = self.pipeline_dir / "dead-letter"
        dl_dir.mkdir(parents=True, exist_ok=True)
        uid = generate_ulid()
        dl_path = dl_dir / f"{uid}.json"
        if isinstance(raw, bytes):
            raw_str = raw.decode("utf-8", errors="replace")
        else:
            raw_str = raw
        content = {"raw": raw_str, "reason": reason, "ts": time.time()}
        with open(str(dl_path), "w") as f:
            json.dump(content, f)
            f.flush()
            os.fsync(f.fileno())
        self._logger.warning("Dead-lettered to %s: %s", dl_path, reason)

    # ═══════════════════════════════════════════════════════════════════
    # Tool: post_message
    # ═══════════════════════════════════════════════════════════════════

    def post_message(
        self,
        from_role: str,
        to_role: str,
        topic: str,
        payload: str,
        message_id: str = "",
        sha: str = "",
    ) -> dict:
        if not isinstance(from_role, str) or from_role not in VALID_ROLES:
            return {
                "status": "error",
                "error": f"invalid from_role: {from_role!r}, "
                         f"must be one of {sorted(VALID_ROLES)}",
            }
        if not isinstance(to_role, str) or to_role not in VALID_ROLES:
            return {
                "status": "error",
                "error": f"invalid to_role: {to_role!r}, "
                         f"must be one of {sorted(VALID_ROLES)}",
            }
        if not isinstance(topic, str) or topic not in ALLOWED_TOPICS:
            return {
                "status": "error",
                "error": f"unknown topic: {topic!r}, "
                         f"allowed: {sorted(ALLOWED_TOPICS)}",
            }
        if not isinstance(payload, str):
            return {"status": "error", "error": "payload must be a string"}

        if not message_id:
            message_id = generate_ulid()
        if self._is_duplicate(message_id):
            return {"status": "duplicate", "message_id": message_id}

        seq = self._next_seq()
        msg: dict = {
            "message_id": message_id,
            "from": from_role,
            "to": to_role,
            "topic": topic,
            "payload": payload,
            "ts": time.time(),
            "seq": seq,
        }
        if sha:
            msg["sha"] = sha

        inbox_path = str(self.pipeline_dir / "inbox" / f"{to_role}.jsonl")
        line = json.dumps(msg, separators=(",", ":"))
        nbytes = self._atomic_append(inbox_path, line)
        self._record_dedup(message_id)

        return {"status": "posted", "message_id": message_id, "bytes": nbytes}

    # ═══════════════════════════════════════════════════════════════════
    # Tool: claim_next
    # ═══════════════════════════════════════════════════════════════════

    def claim_next(self, role: str) -> dict:
        if not isinstance(role, str) or role not in VALID_ROLES:
            return {
                "status": "error",
                "error": f"invalid role: {role!r}, "
                         f"must be one of {sorted(VALID_ROLES)}",
            }

        inbox_path = self.pipeline_dir / "inbox" / f"{role}.jsonl"
        if not inbox_path.exists():
            return {"status": "empty"}

        # Fast check before locking
        try:
            if inbox_path.stat().st_size == 0:
                return {"status": "empty"}
        except OSError:
            return {"status": "empty"}

        first_line: bytes = b""
        with open(str(inbox_path), "r+b") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                first_line = f.readline()
                if not first_line.strip():
                    return {"status": "empty"}

                # Seek+truncate: copy remaining bytes forward in chunks.
                # Never loads entire file into memory — O(n) I/O, O(1) RAM.
                src_pos = f.tell()
                dst_pos = 0
                file_end = f.seek(0, 2)

                while src_pos < file_end:
                    to_read = min(CLAIM_CHUNK, file_end - src_pos)
                    f.seek(src_pos)
                    chunk = f.read(to_read)
                    f.seek(dst_pos)
                    f.write(chunk)
                    n = len(chunk)
                    src_pos += n
                    dst_pos += n

                f.truncate(dst_pos)
                f.flush()
                os.fsync(f.fileno())
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)

        # Parse claimed line
        raw = first_line.strip()
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            self._dead_letter(raw, reason="malformed JSON in inbox")
            return {
                "status": "error",
                "error": "malformed message moved to dead-letter",
            }

        # Audit: write to claimed log
        audit_msg = dict(msg)
        audit_msg["claim_ts"] = time.time()
        claimed_path = str(
            self.pipeline_dir / "inbox" / f"{role}.claimed.jsonl"
        )
        self._atomic_append(
            claimed_path, json.dumps(audit_msg, separators=(",", ":"))
        )

        return msg

    # ═══════════════════════════════════════════════════════════════════
    # Tool: record_verdict
    # ═══════════════════════════════════════════════════════════════════

    def record_verdict(
        self,
        role: str,
        status: str,
        sha: str,
        evidence: str = "",
        findings: str = "",
    ) -> dict:
        if not isinstance(role, str) or role not in VERDICT_STATUSES:
            return {
                "status": "error",
                "error": f"invalid role: {role!r}, "
                         f"must be one of {sorted(VERDICT_STATUSES)}",
            }
        allowed = VERDICT_STATUSES[role]
        if not isinstance(status, str) or status not in allowed:
            return {
                "status": "error",
                "error": f"invalid status {status!r} for {role}, "
                         f"allowed: {sorted(allowed)}",
            }
        if not isinstance(sha, str):
            return {"status": "error", "error": "sha must be a string"}

        verdict_id = generate_ulid()
        seq = self._next_seq()
        record: dict = {
            "id": verdict_id,
            "role": role,
            "status": status,
            "sha": sha,
            "ts": time.time(),
            "seq": seq,
        }
        if evidence:
            record["evidence"] = evidence
        if findings:
            record["findings"] = findings

        verdicts_path = str(self.pipeline_dir / "verdicts.jsonl")
        self._atomic_append(
            verdicts_path, json.dumps(record, separators=(",", ":"))
        )
        return {"status": "recorded", "id": verdict_id}

    # ═══════════════════════════════════════════════════════════════════
    # Tool: request_gate
    # ═══════════════════════════════════════════════════════════════════

    def request_gate(self, gate_name: str) -> dict:
        if not isinstance(gate_name, str) or gate_name not in VALID_GATES:
            return {
                "status": "error",
                "error": f"invalid gate: {gate_name!r}, "
                         f"allowed: {sorted(VALID_GATES)}",
            }

        state_path = self.pipeline_dir / "state.json"
        try:
            with open(str(state_path), "r") as f:
                state = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return {"status": "error", "error": "state.json missing or corrupt"}

        last_gate = state.get("last_gate")
        last_decision = state.get("last_gate_decision")
        last_ts = state.get("last_gate_ts")

        if last_gate != gate_name or last_decision is None:
            return {"status": "no_decision", "gate": gate_name}

        if last_ts is not None:
            age = time.time() - last_ts
            if age > STALE_GATE_SECONDS:
                return {
                    "status": "stale",
                    "gate": gate_name,
                    "age_seconds": round(age, 1),
                }

        return {
            "status": "ok",
            "gate": gate_name,
            "decision": last_decision,
            "ts": last_ts,
        }

    # ═══════════════════════════════════════════════════════════════════
    # Tool: get_latest_diff
    # ═══════════════════════════════════════════════════════════════════

    def get_latest_diff(self, since_ref: str) -> dict:
        if not isinstance(since_ref, str) or not since_ref.strip():
            return {"status": "error", "error": "since_ref must be a non-empty string"}

        # Verify ref exists
        try:
            result = subprocess.run(
                ["git", "rev-parse", "--verify", since_ref],
                capture_output=True, text=True, timeout=10,
                cwd=str(self.repo_root),
            )
            if result.returncode != 0:
                return {"status": "no_ref", "ref": since_ref}
        except subprocess.TimeoutExpired:
            return {"status": "error", "error": "git rev-parse timed out"}
        except FileNotFoundError:
            return {"status": "error", "error": "git not found"}

        # Changed files
        try:
            names = subprocess.run(
                ["git", "diff", "--name-only", f"{since_ref}..HEAD"],
                capture_output=True, text=True, timeout=30,
                cwd=str(self.repo_root),
            )
            changed_files = [f for f in names.stdout.strip().split("\n") if f]
        except (subprocess.TimeoutExpired, FileNotFoundError):
            changed_files = []

        # Unified diff
        try:
            diff_proc = subprocess.run(
                ["git", "diff", "--unified=3", f"{since_ref}..HEAD"],
                capture_output=True, text=True, timeout=30,
                cwd=str(self.repo_root),
            )
            diff_text = diff_proc.stdout
        except (subprocess.TimeoutExpired, FileNotFoundError):
            diff_text = ""

        truncated = False
        if len(diff_text.encode("utf-8")) > MAX_DIFF_BYTES:
            diff_text = diff_text[: MAX_DIFF_BYTES].rsplit("\n", 1)[0]
            truncated = True

        out: dict = {"changed_files": changed_files, "diff": diff_text}
        if truncated:
            out["truncated"] = True
        return out

    # ═══════════════════════════════════════════════════════════════════
    # Tool: acquire_file_lock
    # ═══════════════════════════════════════════════════════════════════

    def acquire_file_lock(
        self, path: str, owner: str, ttl_seconds: int = 120
    ) -> dict:
        if not isinstance(path, str) or not path.strip():
            return {"status": "error", "error": "path must be a non-empty string"}
        if not isinstance(owner, str) or not owner.strip():
            return {"status": "error", "error": "owner must be a non-empty string"}
        if not isinstance(ttl_seconds, (int, float)) or ttl_seconds <= 0:
            return {"status": "error", "error": "ttl_seconds must be a positive number"}

        # Reject paths with ..
        if ".." in path.split("/") or ".." in path.split(os.sep):
            return {"status": "error", "error": "path must not contain '..'"}

        # Reject absolute paths outside repo
        if os.path.isabs(path):
            try:
                resolved = Path(path).resolve()
                if not str(resolved).startswith(str(self.repo_root)):
                    return {
                        "status": "error",
                        "error": "absolute path must be inside the repo",
                    }
            except (ValueError, OSError):
                return {"status": "error", "error": "invalid path"}

        path_hash = hashlib.sha1(path.encode()).hexdigest()
        lock_file = self.pipeline_dir / "locks" / f"{path_hash}.lock"
        token = generate_ulid()
        now = time.time()
        ttl_seconds = int(ttl_seconds)

        lock_data = {
            "owner": owner,
            "acquired_at": now,
            "ttl_seconds": ttl_seconds,
            "path": path,
            "token": token,
        }

        # Attempt O_EXCL create — atomic, only one winner
        try:
            fd = os.open(
                str(lock_file), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644
            )
            try:
                os.write(fd, json.dumps(lock_data, separators=(",", ":")).encode())
                os.fsync(fd)
            finally:
                os.close(fd)
            return {"status": "acquired", "token": token}
        except FileExistsError:
            pass

        # Lock file exists — check TTL
        try:
            with open(str(lock_file), "r") as f:
                existing = json.load(f)
        except (json.JSONDecodeError, FileNotFoundError, OSError):
            # Corrupt or vanished — remove and retry once
            try:
                os.unlink(str(lock_file))
            except OSError:
                pass
            try:
                fd = os.open(
                    str(lock_file),
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o644,
                )
                try:
                    os.write(
                        fd,
                        json.dumps(lock_data, separators=(",", ":")).encode(),
                    )
                    os.fsync(fd)
                finally:
                    os.close(fd)
                return {"status": "acquired", "token": token}
            except FileExistsError:
                return {"status": "held", "held_by": "unknown", "expires_in": 0}

        acquired_at = existing.get("acquired_at", 0)
        existing_ttl = existing.get("ttl_seconds", 120)

        if now >= acquired_at + existing_ttl:
            # Expired — take over
            try:
                os.unlink(str(lock_file))
            except OSError:
                pass

            # Audit the takeover
            audit_entry = {
                "event": "takeover",
                "path": path,
                "old_owner": existing.get("owner"),
                "new_owner": owner,
                "ts": now,
            }
            audit_path = str(self.pipeline_dir / "locks" / "audit.jsonl")
            self._atomic_append(
                audit_path, json.dumps(audit_entry, separators=(",", ":"))
            )

            # Re-create with O_EXCL
            try:
                fd = os.open(
                    str(lock_file),
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o644,
                )
                try:
                    os.write(
                        fd,
                        json.dumps(lock_data, separators=(",", ":")).encode(),
                    )
                    os.fsync(fd)
                finally:
                    os.close(fd)
                return {"status": "acquired", "token": token}
            except FileExistsError:
                # Another process beat us during takeover
                try:
                    with open(str(lock_file), "r") as f2:
                        winner = json.load(f2)
                    exp = max(
                        0,
                        winner.get("acquired_at", 0)
                        + winner.get("ttl_seconds", 120)
                        - now,
                    )
                    return {
                        "status": "held",
                        "held_by": winner.get("owner"),
                        "expires_in": round(exp, 1),
                    }
                except (json.JSONDecodeError, FileNotFoundError, OSError):
                    return {
                        "status": "error",
                        "error": "lock contention, retry",
                    }
        else:
            expires_in = max(0, acquired_at + existing_ttl - now)
            return {
                "status": "held",
                "held_by": existing.get("owner"),
                "expires_in": round(expires_in, 1),
            }

    # ═══════════════════════════════════════════════════════════════════
    # Tool: release_file_lock
    # ═══════════════════════════════════════════════════════════════════

    def release_file_lock(self, path: str, token: str) -> dict:
        if not isinstance(path, str) or not path.strip():
            return {"status": "error", "error": "path must be a non-empty string"}
        if not isinstance(token, str) or not token.strip():
            return {"status": "error", "error": "token must be a non-empty string"}

        path_hash = hashlib.sha1(path.encode()).hexdigest()
        lock_file = self.pipeline_dir / "locks" / f"{path_hash}.lock"

        if not lock_file.exists():
            return {"status": "error", "error": "no lock held for this path"}

        try:
            with open(str(lock_file), "r") as f:
                existing = json.load(f)
        except (json.JSONDecodeError, FileNotFoundError, OSError):
            return {"status": "error", "error": "lock file corrupt or missing"}

        if existing.get("token") != token:
            return {"status": "rejected", "held_by": existing.get("owner")}

        os.unlink(str(lock_file))

        # Audit
        audit_entry = {
            "event": "release",
            "path": path,
            "owner": existing.get("owner"),
            "token": token,
            "ts": time.time(),
        }
        audit_path = str(self.pipeline_dir / "locks" / "audit.jsonl")
        self._atomic_append(
            audit_path, json.dumps(audit_entry, separators=(",", ":"))
        )
        return {"status": "released"}

    # ═══════════════════════════════════════════════════════════════════
    # Tool: heartbeat
    # ═══════════════════════════════════════════════════════════════════

    def heartbeat(self, role: str) -> dict:
        if not isinstance(role, str) or role not in VALID_ROLES:
            return {
                "status": "error",
                "error": f"invalid role: {role!r}, "
                         f"must be one of {sorted(VALID_ROLES)}",
            }

        hb_dir = self.pipeline_dir / "heartbeat"
        hb_dir.mkdir(parents=True, exist_ok=True)
        ts = int(time.time())
        hb_path = hb_dir / f"{role}.txt"
        with open(str(hb_path), "w") as f:
            f.write(str(ts))
            f.flush()
            os.fsync(f.fileno())

        return {"status": "ok", "ts": ts}


# ═══════════════════════════════════════════════════════════════════════════
# MCP server wiring
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_PIPELINE_DIR = DEFAULT_REPO_ROOT / ".pipeline"

_pipeline_dir = Path(
    os.environ.get("PIPELINE_DIR", str(DEFAULT_PIPELINE_DIR))
)
_repo_root = Path(os.environ.get("REPO_ROOT", str(DEFAULT_REPO_ROOT)))

# Logging — file only, never stderr (protects the JSON-RPC channel)
_pipeline_dir.mkdir(parents=True, exist_ok=True)
_log_path = _pipeline_dir / "mcp-server.log"
_file_handler = logging.FileHandler(str(_log_path))
_file_handler.setFormatter(
    logging.Formatter("%(asctime)s %(levelname)s %(message)s")
)
_logger = logging.getLogger("mcp-coord")
_logger.addHandler(_file_handler)
_logger.setLevel(logging.DEBUG)

# Global coordinator instance
coord = Coordinator(_pipeline_dir, _repo_root)

# FastMCP server
server = FastMCP("pipeline-coordinator")


def _safe(fn, *args, **kwargs) -> str:
    """Call fn, catch all exceptions, return JSON string."""
    try:
        result = fn(*args, **kwargs)
        return json.dumps(result)
    except Exception as exc:
        _logger.exception("Tool call failed: %s", fn.__name__)
        try:
            coord._dead_letter(
                json.dumps({"args": [str(a) for a in args], "kwargs": {k: str(v) for k, v in kwargs.items()}}),
                reason=f"exception in {fn.__name__}: {exc}",
            )
        except Exception:
            pass
        return json.dumps({"status": "error", "error": str(exc)})


# ── MCP tool definitions ──────────────────────────────────────────────


@server.tool()
def post_message(
    from_role: str,
    to_role: str,
    topic: str,
    payload: str,
    message_id: str = "",
    sha: str = "",
) -> str:
    """Post a typed message from one orchestrator role to another.

    Args:
        from_role: Source role (supervisor, delivery, security, quality, bootstrap)
        to_role: Destination role
        topic: Message topic from the allowed set
        payload: Message body
        message_id: Optional ULID — server generates one if omitted. Duplicates within 24h rejected.
        sha: Optional git SHA to associate with the message
    """
    return _safe(coord.post_message, from_role, to_role, topic, payload, message_id, sha)


@server.tool()
def claim_next(role: str) -> str:
    """Atomically pop the oldest unclaimed message from a role's inbox.

    Args:
        role: The role whose inbox to claim from (supervisor, delivery, security, quality, bootstrap)
    """
    return _safe(coord.claim_next, role)


@server.tool()
def record_verdict(
    role: str,
    status: str,
    sha: str,
    evidence: str = "",
    findings: str = "",
) -> str:
    """Record a gate verdict from a reviewer role.

    Args:
        role: The reviewer role (delivery, security, quality)
        status: Verdict status. delivery: IN_PROGRESS|BUILT|DONE|BLOCKED. security: PASS|FAIL|STALE. quality: READY|READY_WITH_FIXES|NOT_READY|STALE.
        sha: Git commit SHA being reviewed
        evidence: Optional supporting evidence
        findings: Optional detailed findings
    """
    return _safe(coord.record_verdict, role, status, sha, evidence, findings)


@server.tool()
def request_gate(gate_name: str) -> str:
    """Read the supervisor's cached gate decision from state.json.

    Args:
        gate_name: Gate to query (gate_security, gate_quality, gate_terminate)
    """
    return _safe(coord.request_gate, gate_name)


@server.tool()
def get_latest_diff(since_ref: str) -> str:
    """Get the git diff from a reference to HEAD, truncated at 64KB.

    Args:
        since_ref: Git ref to diff against (branch, tag, or commit SHA)
    """
    return _safe(coord.get_latest_diff, since_ref)


@server.tool()
def acquire_file_lock(
    path: str, owner: str, ttl_seconds: int = 120
) -> str:
    """Acquire an exclusive file lock for coordinated writes.

    Args:
        path: Repo-relative file path to lock (must be inside the repo, no '..')
        owner: Role name acquiring the lock
        ttl_seconds: Lock TTL in seconds (default 120). Expired locks are taken over.
    """
    return _safe(coord.acquire_file_lock, path, owner, ttl_seconds)


@server.tool()
def release_file_lock(path: str, token: str) -> str:
    """Release a previously acquired file lock.

    Args:
        path: The same path used in acquire_file_lock
        token: The token returned by acquire_file_lock
    """
    return _safe(coord.release_file_lock, path, token)


@server.tool()
def heartbeat(role: str) -> str:
    """Write a heartbeat timestamp for a role. Used by the bash watchdog.

    Args:
        role: The orchestrator role sending the heartbeat
    """
    return _safe(coord.heartbeat, role)


# ═══════════════════════════════════════════════════════════════════════════
# Entry point
# ═══════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    server.run(transport="stdio")
