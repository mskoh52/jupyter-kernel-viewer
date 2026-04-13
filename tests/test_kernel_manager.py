"""
Integration tests for the Jupyter server REST API used by manager.lua.
All HTTP calls are made directly via urllib — no project imports.
"""

import json
import urllib.request
import urllib.error


def api(base, token, method, path, body=None):
    url = f"{base}{path}?token={token}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method)
    if data:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=10) as r:
        raw = r.read()
        return r.status, json.loads(raw) if raw else None


def _start_kernel(base, token):
    status, info = api(base, token, "POST", "/api/kernels", {"name": "python3"})
    assert status == 201
    return info["id"]


def _delete_kernel(base, token, kernel_id):
    try:
        api(base, token, "DELETE", f"/api/kernels/{kernel_id}")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_list_kernels_empty(jupyter_server):
    base = jupyter_server["base"]
    token = jupyter_server["token"]
    status, kernels = api(base, token, "GET", "/api/kernels")
    assert status == 200
    assert isinstance(kernels, list)


def test_start_kernel(jupyter_server):
    base = jupyter_server["base"]
    token = jupyter_server["token"]
    status, info = api(base, token, "POST", "/api/kernels", {"name": "python3"})
    try:
        assert status == 201
        assert "id" in info
        assert "name" in info
    finally:
        _delete_kernel(base, token, info["id"])


def test_kill_kernel(jupyter_server):
    base = jupyter_server["base"]
    token = jupyter_server["token"]
    kernel_id = _start_kernel(base, token)

    del_url = f"{base}/api/kernels/{kernel_id}?token={token}"
    req = urllib.request.Request(del_url, method="DELETE")
    with urllib.request.urlopen(req, timeout=10) as resp:
        assert resp.status == 204

    _, kernels = api(base, token, "GET", "/api/kernels")
    ids = [k["id"] for k in kernels]
    assert kernel_id not in ids


def test_list_kernels_after_start(jupyter_server):
    base = jupyter_server["base"]
    token = jupyter_server["token"]
    kernel_id = _start_kernel(base, token)
    try:
        _, kernels = api(base, token, "GET", "/api/kernels")
        ids = [k["id"] for k in kernels]
        assert kernel_id in ids
    finally:
        _delete_kernel(base, token, kernel_id)


def test_interrupt_kernel(jupyter_server, kernel):
    base = jupyter_server["base"]
    token = jupyter_server["token"]
    kernel_id = kernel["id"]
    status, _ = api(base, token, "POST", f"/api/kernels/{kernel_id}/interrupt")
    assert status in (200, 204)


def test_restart_kernel(jupyter_server, kernel):
    base = jupyter_server["base"]
    token = jupyter_server["token"]
    kernel_id = kernel["id"]
    status, info = api(base, token, "POST", f"/api/kernels/{kernel_id}/restart")
    assert status == 200
    assert "id" in info
