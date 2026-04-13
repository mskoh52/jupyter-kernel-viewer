"""
Integration tests for kernel_bridge.py.
The bridge is spawned as a subprocess; we communicate via stdin/stdout JSON lines.
"""

import json
import queue
import subprocess
import sys
import threading
from pathlib import Path

BRIDGE_PATH = Path(__file__).parent.parent / "nvim-jupyter" / "python" / "kernel_bridge.py"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def start_bridge(server_url):
    """Start kernel_bridge.py subprocess connected to server_url."""
    proc = subprocess.Popen(
        [sys.executable, str(BRIDGE_PATH), server_url],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    return proc


def read_msg(proc, timeout=10):
    """Read one JSON line from bridge stdout, with timeout."""
    result_q = queue.Queue()

    def _reader():
        try:
            line = proc.stdout.readline()
            result_q.put(line)
        except Exception as exc:
            result_q.put(exc)

    t = threading.Thread(target=_reader, daemon=True)
    t.start()
    try:
        line = result_q.get(timeout=timeout)
    except queue.Empty:
        raise TimeoutError(f"No message from bridge within {timeout}s")
    if isinstance(line, Exception):
        raise line
    line = line.strip()
    if not line:
        raise ValueError("Bridge stdout closed (empty line)")
    return json.loads(line)


def send_msg(proc, msg):
    """Send a JSON message to the bridge stdin."""
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()


def collect_until_idle(proc, timeout=30):
    """
    Read messages from the bridge until we receive a status with
    execution_state == "idle" for a non-None id, or until timeout.
    Returns the list of all messages collected (including the idle status).
    """
    messages = []
    deadline_per_msg = timeout
    while True:
        msg = read_msg(proc, timeout=deadline_per_msg)
        messages.append(msg)
        if (
            msg.get("type") == "status"
            and msg.get("execution_state") == "idle"
            and msg.get("id") is not None
        ):
            break
    return messages


def shutdown_bridge(proc):
    """Send shutdown and wait for process to exit."""
    try:
        send_msg(proc, {"type": "shutdown"})
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
        proc.wait()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_bridge_connects(jupyter_server, kernel):
    """Bridge should emit a 'ready' message when exactly one kernel is running."""
    server_url = jupyter_server["url"]
    kernel_id = kernel["id"]

    proc = start_bridge(server_url)
    try:
        msg = read_msg(proc, timeout=15)
        assert msg["type"] == "ready", f"Expected 'ready', got: {msg}"
        assert msg["kernel_id"] == kernel_id
    finally:
        shutdown_bridge(proc)


def test_bridge_execute(jupyter_server, kernel):
    """Execute '1 + 1' and assert an execute_result with '2' in output."""
    server_url = jupyter_server["url"]

    proc = start_bridge(server_url)
    try:
        # Wait for ready
        msg = read_msg(proc, timeout=15)
        assert msg["type"] == "ready"

        send_msg(proc, {"type": "execute", "id": "req1", "code": "1 + 1"})
        messages = collect_until_idle(proc, timeout=30)

        results = [m for m in messages if m.get("type") == "execute_result"]
        assert results, f"No execute_result in: {messages}"
        result = results[0]
        assert "execution_count" in result
        assert "2" in result["data"].get("text/plain", "")
    finally:
        shutdown_bridge(proc)


def test_bridge_execute_print(jupyter_server, kernel):
    """Execute print('hello') and assert a stream message with 'hello'."""
    server_url = jupyter_server["url"]

    proc = start_bridge(server_url)
    try:
        msg = read_msg(proc, timeout=15)
        assert msg["type"] == "ready"

        send_msg(proc, {"type": "execute", "id": "req2", "code": "print('hello')"})
        messages = collect_until_idle(proc, timeout=30)

        streams = [m for m in messages if m.get("type") == "stream" and m.get("name") == "stdout"]
        assert streams, f"No stdout stream message in: {messages}"
        combined = "".join(m.get("text", "") for m in streams)
        assert "hello" in combined
    finally:
        shutdown_bridge(proc)


def test_bridge_execute_error(jupyter_server, kernel):
    """Execute code that raises an error and assert an error message."""
    server_url = jupyter_server["url"]

    proc = start_bridge(server_url)
    try:
        msg = read_msg(proc, timeout=15)
        assert msg["type"] == "ready"

        send_msg(proc, {"type": "execute", "id": "req3", "code": "raise ValueError('oops')"})
        messages = collect_until_idle(proc, timeout=30)

        errors = [m for m in messages if m.get("type") == "error"]
        assert errors, f"No error message in: {messages}"
        assert errors[0]["ename"] == "ValueError"
    finally:
        shutdown_bridge(proc)
