#!/usr/bin/env python3
"""Streaming-input wrapper for long-running Claude orchestrators.

Spawns a persistent `claude --print --input-format stream-json` subprocess,
feeds it the orchestrator prompt as the first user message, then sends
periodic "continue your loop" messages every --cycle-seconds.

The wrapper handles:
  - Heartbeat file updates (atomic write via temp+rename)
  - Log rotation when the log exceeds 50 MB
  - Graceful shutdown on SIGTERM/SIGINT
  - Exit code 42 for context-pressure events (watchdog treats as expected restart)
  - Rate-limit pause when overage is rejected (avoids retry storms)
"""

import argparse
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

MAX_LOG_BYTES = 50 * 1024 * 1024  # 50 MB
RATE_LIMIT_PAUSE = 300  # 5 minutes
SHUTDOWN_WAIT = 30
SHUTDOWN_KILL_WAIT = 10

CONTINUE_MESSAGE = (
    "Execute one complete pass of your orchestrator cycle now: "
    "drain your inbox (claim_next), reconcile state, perform your "
    "role-specific work, record a verdict, post heartbeat. Report "
    "at the end of this turn what you did. Do not stop until the "
    "cycle is complete \u2014 do multiple tool calls as needed."
)


def make_user_message(content: str) -> bytes:
    """Build a stream-json user message and return it as newline-terminated bytes."""
    msg = {"type": "user", "message": {"role": "user", "content": content}}
    return (json.dumps(msg, ensure_ascii=False) + "\n").encode()


def write_heartbeat(path: str) -> None:
    """Atomically write the current unix timestamp to the heartbeat file."""
    dir_name = os.path.dirname(path)
    try:
        fd, tmp = tempfile.mkstemp(dir=dir_name, prefix=".hb-")
        with os.fdopen(fd, "w") as f:
            f.write(str(int(time.time())))
        os.replace(tmp, path)
    except OSError as e:
        log(f"heartbeat write failed: {e}")


def rotate_log(path: str) -> None:
    """Rotate log file if it exceeds MAX_LOG_BYTES."""
    try:
        if os.path.exists(path) and os.path.getsize(path) > MAX_LOG_BYTES:
            rotated = path + ".1"
            shutil.move(path, rotated)
            log(f"log rotated: {path} -> {rotated}")
    except OSError as e:
        log(f"log rotation failed: {e}")


def log(msg: str) -> None:
    """Print a timestamped message to stderr."""
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[wrapper {ts}] {msg}", file=sys.stderr, flush=True)


def check_context_pressure(line: str) -> bool:
    """Check if a stream-json output line indicates context pressure/compaction."""
    try:
        event = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        return False
    subtype = event.get("subtype", "")
    if subtype in ("compact_boundary", "context_pressure", "compaction"):
        return True
    return False


def check_rate_limit_rejected(line: str) -> bool:
    """Check if a stream-json output line is a rejected rate-limit event."""
    try:
        event = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        return False
    if event.get("type") == "system" and event.get("subtype") == "api_retry":
        if event.get("error") == "rate_limit":
            return True
    return False


def build_claude_args(args: argparse.Namespace, is_resume: bool) -> list[str]:
    """Build the claude subprocess command line."""
    cmd = ["claude", "--print"]

    if is_resume:
        cmd += ["--resume", args.session_id]
    else:
        cmd += ["--session-id", args.session_id]

    cmd += [
        "--name", args.role,
        "--model", args.model,
        "--effort", args.effort,
        "--mcp-config", args.mcp_config,
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--permission-mode", "default",
    ]
    return cmd


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Streaming-input wrapper for Claude orchestrators"
    )
    p.add_argument("--role", required=True,
                   choices=["supervisor", "delivery", "security", "quality"],
                   help="Orchestrator role")
    p.add_argument("--session-id", required=True,
                   help="Deterministic UUID for the session")
    p.add_argument("--prompt-file", required=True,
                   help="Path to the orchestrator .prompt.md file")
    p.add_argument("--mcp-config", required=True,
                   help="Path to the project's .pipeline/mcp.json")
    p.add_argument("--log-file", required=True,
                   help="Path to the project's .pipeline/logs/<role>.jsonl")
    p.add_argument("--heartbeat-file", required=True,
                   help="Path to the project's .pipeline/heartbeat/<role>.txt")
    p.add_argument("--model", default="opus",
                   help="Claude model alias (default: opus)")
    p.add_argument("--effort", default="max",
                   choices=["low", "medium", "high", "xhigh", "max"],
                   help="Effort level (default: max)")
    p.add_argument("--cycle-seconds", type=int, default=60,
                   help="Seconds between continue messages (default: 60)")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    # -- Validate preconditions --
    if not os.path.isfile(args.prompt_file):
        log(f"prompt file not found: {args.prompt_file}")
        return 1
    if os.path.getsize(args.prompt_file) == 0:
        log(f"prompt file is empty: {args.prompt_file}")
        return 1
    if not os.path.isfile(args.mcp_config):
        log(f"mcp config not found: {args.mcp_config}")
        return 1
    if not shutil.which("claude"):
        log("claude binary not found on PATH")
        return 1

    # Read the orchestrator prompt
    with open(args.prompt_file, "r") as f:
        prompt_text = f.read()

    # Determine if this is a resume (log file already has content from a prior run)
    is_resume = (
        os.path.isfile(args.log_file) and os.path.getsize(args.log_file) > 0
    )

    # Ensure log directory exists
    os.makedirs(os.path.dirname(args.log_file), exist_ok=True)
    os.makedirs(os.path.dirname(args.heartbeat_file), exist_ok=True)

    # Build claude command
    claude_cmd = build_claude_args(args, is_resume)
    log(f"launching: {' '.join(claude_cmd)}")
    log(f"resume={is_resume}, cycle={args.cycle_seconds}s")

    # Open log file for appending (stdout + stderr tee target)
    log_fd = open(args.log_file, "ab", buffering=0)

    # Spawn claude subprocess
    proc = subprocess.Popen(
        claude_cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    # -- Shutdown handling --
    shutting_down = False

    def handle_signal(signum, frame):
        nonlocal shutting_down
        if shutting_down:
            return
        shutting_down = True
        sig_name = signal.Signals(signum).name
        log(f"received {sig_name} - initiating graceful shutdown")

        # Send a final shutdown message to claude
        if proc.stdin and not proc.stdin.closed:
            try:
                shutdown_msg = make_user_message(
                    "Shutdown signal received. Save your state and exit gracefully."
                )
                proc.stdin.write(shutdown_msg)
                proc.stdin.flush()
                proc.stdin.close()
            except (BrokenPipeError, OSError):
                pass

        # Wait for claude to exit
        try:
            proc.wait(timeout=SHUTDOWN_WAIT)
        except subprocess.TimeoutExpired:
            log("claude did not exit in time - sending SIGTERM")
            proc.terminate()
            try:
                proc.wait(timeout=SHUTDOWN_KILL_WAIT)
            except subprocess.TimeoutExpired:
                log("claude still running - sending SIGKILL")
                proc.kill()
                proc.wait()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # -- Send the initial prompt --
    context_pressure_seen = False
    try:
        if is_resume:
            initial_msg = make_user_message(
                "Session resumed after restart. " + CONTINUE_MESSAGE
            )
        else:
            initial_msg = make_user_message(prompt_text)

        proc.stdin.write(initial_msg)
        proc.stdin.flush()
        log(f"sent initial {'resume' if is_resume else 'prompt'} message")
    except (BrokenPipeError, OSError) as e:
        log(f"failed to send initial message: {e}")
        proc.wait()
        log_fd.close()
        return 1

    # -- Main loop --
    last_continue = time.time()

    while not shutting_down:
        # Check if claude has exited
        if proc.poll() is not None:
            log(f"claude exited with code {proc.returncode}")
            break

        # Poll stdout for output (non-blocking, 1-second intervals)
        try:
            readable, _, _ = select.select(
                [proc.stdout, proc.stderr], [], [], 1.0
            )
        except (ValueError, OSError):
            # File descriptors closed during shutdown
            break

        for fd in readable:
            try:
                line = fd.readline()
            except (ValueError, OSError):
                continue
            if not line:
                continue

            if fd is proc.stderr:
                prefixed = b"STDERR: " + line
                log_fd.write(prefixed)
            else:
                log_fd.write(line)
                # Check for context pressure
                line_str = line.decode("utf-8", errors="replace").strip()
                if check_context_pressure(line_str):
                    context_pressure_seen = True
                    log("context pressure detected - will exit 42")
                # Check for rate limit rejection
                if check_rate_limit_rejected(line_str):
                    log(f"rate limit hit - pausing {RATE_LIMIT_PAUSE}s")
                    last_continue = time.time() + RATE_LIMIT_PAUSE - args.cycle_seconds

        # Send periodic continue messages
        now = time.time()
        if (now - last_continue) >= args.cycle_seconds and not shutting_down:
            if proc.poll() is not None:
                break

            try:
                proc.stdin.write(make_user_message(CONTINUE_MESSAGE))
                proc.stdin.flush()
                log("sent continue message")
            except (BrokenPipeError, OSError):
                log("broken pipe on continue message - claude likely exited")
                break

            write_heartbeat(args.heartbeat_file)
            rotate_log(args.log_file)
            last_continue = now

    # -- Drain remaining output --
    if proc.poll() is None:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass

    for fd in [proc.stdout, proc.stderr]:
        if fd:
            try:
                remaining = fd.read()
                if remaining:
                    log_fd.write(remaining)
            except (ValueError, OSError):
                pass

    log_fd.close()

    # -- Determine exit code --
    if context_pressure_seen:
        log("exiting 42 (context pressure)")
        return 42

    rc = proc.returncode if proc.returncode is not None else 1
    if rc == 0:
        log("exiting 0 (normal)")
    else:
        log(f"exiting {rc}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
