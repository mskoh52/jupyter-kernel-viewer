#!/usr/bin/env python3
"""
Jupyter kernel bridge: reads JSON commands from stdin, writes JSON results to stdout.
Accepts either:
  - A connection file path (e.g. /path/to/kernel-abc.json)
  - A Jupyter server URL  (e.g. http://localhost:8888?token=abc)
"""

import sys
import json
import threading
import queue
import urllib.request
import urllib.parse

try:
    import jupyter_client
    from jupyter_client import find_connection_file
except ImportError:
    print(json.dumps({"type": "error", "message": "jupyter_client is not installed. Run: pip install jupyter_client"}), flush=True)
    sys.exit(1)

try:
    import zmq  # noqa: F401
except ImportError:
    print(json.dumps({"type": "error", "message": "pyzmq is not installed. Run: pip install pyzmq"}), flush=True)
    sys.exit(1)


def send(msg):
    print(json.dumps(msg), flush=True)


def parse_server_url(arg):
    """Return (base_url, token) from a URL like http://localhost:8888?token=abc"""
    u = urllib.parse.urlparse(arg)
    params = urllib.parse.parse_qs(u.query)
    token = params.get("token", [""])[0]
    base = urllib.parse.urlunparse((u.scheme, u.netloc, u.path.rstrip("/"), "", "", ""))
    return base, token


def fetch_kernels(base, token):
    url = f"{base}/api/kernels"
    if token:
        url += f"?token={urllib.parse.quote(token)}"
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def connect_via_url(arg):
    """
    Given a Jupyter server URL, fetch kernels, prompt for selection if needed,
    then return a connected BlockingKernelClient.
    """
    base, token = parse_server_url(arg)
    try:
        kernels = fetch_kernels(base, token)
    except Exception as e:
        send({"type": "error", "message": f"Failed to fetch kernels from {base}: {e}"})
        sys.exit(1)

    if len(kernels) == 0:
        send({"type": "error", "message": "No running kernels found on the server"})
        sys.exit(1)
    elif len(kernels) == 1:
        kernel_id = kernels[0]["id"]
    else:
        send({"type": "kernel_list", "kernels": [
            {"id": k["id"], "name": k["name"], "execution_state": k.get("execution_state", "")}
            for k in kernels
        ]})
        while True:
            line = sys.stdin.readline()
            if not line:
                sys.exit(0)
            line = line.strip()
            if not line:
                continue
            try:
                cmd = json.loads(line)
            except json.JSONDecodeError:
                continue
            if cmd.get("type") == "select_kernel":
                kernel_id = cmd["id"]
                break

    try:
        cf = find_connection_file(f"kernel-{kernel_id}.json")
    except Exception as e:
        send({"type": "error", "message": f"Could not find connection file for kernel {kernel_id}: {e}"})
        sys.exit(1)

    client = jupyter_client.BlockingKernelClient(connection_file=cf)
    client.load_connection_file()
    client.start_channels()
    try:
        client.wait_for_ready(timeout=10)
    except RuntimeError as e:
        send({"type": "error", "message": f"Kernel not ready: {e}"})
        sys.exit(1)

    send({"type": "ready", "connection_file": cf, "kernel_id": kernel_id})
    return client, None


def run_iopub_listener(client, callbacks, callbacks_lock, shutdown_event):
    """Read from iopub socket and dispatch messages to stdout."""
    while not shutdown_event.is_set():
        try:
            msg = client.get_iopub_msg(timeout=0.5)
        except queue.Empty:
            continue
        except Exception as e:
            sys.stderr.write(f"iopub error: {e}\n")
            sys.stderr.flush()
            continue

        msg_type = msg["msg_type"]
        parent_id = msg.get("parent_header", {}).get("msg_id", None)

        with callbacks_lock:
            req_id = None
            for rid, info in list(callbacks.items()):
                if info.get("msg_id") == parent_id:
                    req_id = rid
                    break

        content = msg["content"]

        if msg_type == "stream":
            send({"type": "stream", "id": req_id, "name": content.get("name", "stdout"), "text": content.get("text", "")})
        elif msg_type == "execute_result":
            send({"type": "execute_result", "id": req_id, "data": content.get("data", {}), "execution_count": content.get("execution_count")})
        elif msg_type == "display_data":
            send({"type": "display_data", "id": req_id, "data": content.get("data", {})})
        elif msg_type == "error":
            send({"type": "error", "id": req_id, "ename": content.get("ename", ""), "evalue": content.get("evalue", ""), "traceback": content.get("traceback", [])})
        elif msg_type == "status":
            execution_state = content.get("execution_state", "")
            send({"type": "status", "id": req_id, "execution_state": execution_state})
            if execution_state == "idle" and req_id is not None:
                with callbacks_lock:
                    callbacks.pop(req_id, None)
        elif msg_type == "execute_input":
            send({"type": "execute_input", "id": req_id, "code": content.get("code", ""), "execution_count": content.get("execution_count")})


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    km = None

    try:
        if arg and (arg.startswith("http://") or arg.startswith("https://")):
            client, km = connect_via_url(arg)
        elif arg:
            client = jupyter_client.BlockingKernelClient(connection_file=arg)
            client.load_connection_file()
            client.start_channels()
            try:
                client.wait_for_ready(timeout=10)
            except RuntimeError as e:
                send({"type": "error", "message": f"Kernel not ready: {e}"})
                sys.exit(1)
            send({"type": "ready", "connection_file": arg})
        else:
            send({"type": "error", "message": "No connection argument provided. Pass a server URL (http://...) or connection file path."})
            sys.exit(1)
    except Exception as e:
        send({"type": "error", "message": str(e)})
        sys.exit(1)

    callbacks = {}
    callbacks_lock = threading.Lock()
    shutdown_event = threading.Event()

    iopub_thread = threading.Thread(
        target=run_iopub_listener,
        args=(client, callbacks, callbacks_lock, shutdown_event),
        daemon=True,
    )
    iopub_thread.start()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            send({"type": "error", "message": f"Invalid JSON: {line}"})
            continue

        cmd_type = cmd.get("type")

        if cmd_type == "execute":
            req_id = cmd.get("id")
            code = cmd.get("code", "")
            try:
                msg_id = client.execute(code)
            except Exception as e:
                send({"type": "error", "id": req_id, "ename": "BridgeError", "evalue": str(e), "traceback": []})
                continue
            with callbacks_lock:
                callbacks[req_id] = {"msg_id": msg_id}

        elif cmd_type == "complete":
            req_id = cmd.get("id")
            code = cmd.get("code", "")
            cursor_pos = cmd.get("cursor_pos", len(code))
            client.complete(code, cursor_pos)
            try:
                reply = client.get_shell_msg(timeout=5)
                content = reply["content"]
                send({"type": "complete_reply", "id": req_id, "matches": content.get("matches", []), "cursor_start": content.get("cursor_start", cursor_pos), "cursor_end": content.get("cursor_end", cursor_pos)})
            except queue.Empty:
                send({"type": "complete_reply", "id": req_id, "matches": [], "cursor_start": cursor_pos, "cursor_end": cursor_pos})

        elif cmd_type == "interrupt":
            try:
                if km:
                    km.interrupt_kernel()
                else:
                    client.interrupt_kernel()
            except Exception as e:
                send({"type": "error", "message": f"Interrupt failed: {e}"})

        elif cmd_type == "shutdown":
            shutdown_event.set()
            try:
                client.stop_channels()
                if km:
                    km.shutdown_kernel(now=True)
            except Exception:
                pass
            sys.exit(0)

        else:
            send({"type": "error", "message": f"Unknown command type: {cmd_type}"})

    shutdown_event.set()
    client.stop_channels()
    if km:
        km.shutdown_kernel(now=True)


if __name__ == "__main__":
    main()
