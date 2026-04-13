"""
Pytest fixtures for jupyter-kernel-viewer integration tests.
"""

import json
import socket
import subprocess
import sys
import time
import urllib.request

import pytest


def _find_free_port():
    """Find an unused TCP port in the range 19000–29999."""
    for port in range(19000, 30000):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise RuntimeError("No free port found in range 19000–29999")


@pytest.fixture(scope="session")
def jupyter_server():
    """Start a Jupyter server once for the entire test session."""
    port = _find_free_port()
    token = "testtoken"

    proc = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "jupyter",
            "server",
            f"--port={port}",
            "--ip=127.0.0.1",
            "--no-browser",
            f"--ServerApp.token={token}",
            "--ServerApp.password=",
            "--ServerApp.open_browser=False",
            "--ServerApp.disable_check_xsrf=True",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    base = f"http://127.0.0.1:{port}"
    health_url = f"{base}/api/kernels?token={token}"

    deadline = time.time() + 15
    ready = False
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(health_url, timeout=2) as resp:
                if resp.status == 200:
                    ready = True
                    break
        except Exception:
            time.sleep(0.3)

    if not ready:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        pytest.fail(f"Jupyter server on port {port} did not become ready within 15 seconds")

    yield {
        "url": f"{base}?token={token}",
        "port": port,
        "token": token,
        "base": base,
    }

    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


@pytest.fixture(scope="function")
def kernel(jupyter_server):
    """Start a single python3 kernel for a test, then clean it up."""
    base = jupyter_server["base"]
    token = jupyter_server["token"]

    url = f"{base}/api/kernels?token={token}"
    body = json.dumps({"name": "python3"}).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        kernel_info = json.loads(resp.read())

    yield kernel_info

    kernel_id = kernel_info["id"]
    try:
        del_url = f"{base}/api/kernels/{kernel_id}?token={token}"
        req = urllib.request.Request(del_url, method="DELETE")
        with urllib.request.urlopen(req, timeout=10):
            pass
    except Exception:
        pass
