#!/usr/bin/env python3
"""
One-shot Jupyter kernel manager via REST API.

Usage:
    python kernel_manager.py <server_url> <json_command>

server_url: e.g. http://localhost:8888?token=abc
json_command: JSON string with a "type" field
"""

import sys
import json
import urllib.request
import urllib.parse


def parse_server_url(arg):
    u = urllib.parse.urlparse(arg)
    params = urllib.parse.parse_qs(u.query)
    token = params.get("token", [""])[0]
    base = urllib.parse.urlunparse((u.scheme, u.netloc, u.path.rstrip("/"), "", "", ""))
    return base, token


def make_url(base, path, token):
    url = f"{base}{path}"
    if token:
        url += f"?token={urllib.parse.quote(token)}"
    return url


def http_get(url):
    with urllib.request.urlopen(urllib.request.Request(url), timeout=10) as resp:
        return json.loads(resp.read())


def http_post(url, body=None):
    data = json.dumps(body).encode() if body is not None else b""
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def http_delete(url):
    req = urllib.request.Request(url, method="DELETE")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status


def cmd_list(base, token):
    kernels = http_get(make_url(base, "/api/kernels", token))
    result = [
        {"id": k["id"], "name": k["name"], "execution_state": k.get("execution_state", "")}
        for k in kernels
    ]
    print(json.dumps({"type": "kernel_list", "kernels": result}))


def cmd_kill(base, token, kernel_id):
    http_delete(make_url(base, f"/api/kernels/{urllib.parse.quote(kernel_id)}", token))
    print(json.dumps({"type": "killed", "id": kernel_id}))


def cmd_start(base, token, kernel_name):
    k = http_post(make_url(base, "/api/kernels", token), {"name": kernel_name})
    print(json.dumps({
        "type": "started",
        "kernel": {
            "id": k["id"],
            "name": k["name"],
            "execution_state": k.get("execution_state", ""),
        },
    }))


def cmd_restart(base, token, kernel_id):
    http_post(make_url(base, f"/api/kernels/{urllib.parse.quote(kernel_id)}/restart", token))
    print(json.dumps({"type": "restarted", "id": kernel_id}))


def cmd_interrupt(base, token, kernel_id):
    http_post(make_url(base, f"/api/kernels/{urllib.parse.quote(kernel_id)}/interrupt", token))
    print(json.dumps({"type": "interrupted", "id": kernel_id}))


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"type": "error", "message": "Usage: kernel_manager.py <server_url> <json_command>"}))
        sys.exit(1)

    server_url = sys.argv[1]
    json_command = sys.argv[2]

    try:
        base, token = parse_server_url(server_url)
        cmd = json.loads(json_command)
        cmd_type = cmd.get("type")

        if cmd_type == "list":
            cmd_list(base, token)
        elif cmd_type == "kill":
            cmd_kill(base, token, cmd["id"])
        elif cmd_type == "start":
            cmd_start(base, token, cmd.get("kernel_name", "python3"))
        elif cmd_type == "restart":
            cmd_restart(base, token, cmd["id"])
        elif cmd_type == "interrupt":
            cmd_interrupt(base, token, cmd["id"])
        else:
            print(json.dumps({"type": "error", "message": f"Unknown command type: {cmd_type}"}))
            sys.exit(1)

    except Exception as e:
        print(json.dumps({"type": "error", "message": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
