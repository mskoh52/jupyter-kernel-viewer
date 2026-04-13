#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source venv/bin/activate

# Pick a free port in 19000-29999
PORT=$(python3 -c "
import socket, random
for _ in range(20):
    p = random.randint(19000, 29999)
    try:
        s = socket.socket(); s.bind(('127.0.0.1', p)); s.close(); print(p); break
    except OSError: pass
")

TOKEN="luatesttoken"
URL="http://127.0.0.1:${PORT}?token=${TOKEN}"

# Start server
jupyter server \
  --port="$PORT" \
  --ip=127.0.0.1 \
  --no-browser \
  --ServerApp.token="$TOKEN" \
  --ServerApp.password='' \
  --ServerApp.open_browser=False \
  --ServerApp.disable_check_xsrf=True \
  > /tmp/jupyter_lua_test.log 2>&1 &
SERVER_PID=$!

# Wait up to 15s
echo "Waiting for Jupyter server on port $PORT..."
python3 - <<EOF
import urllib.request, time, sys
for _ in range(30):
    try:
        urllib.request.urlopen("http://127.0.0.1:${PORT}/api/kernels?token=${TOKEN}", timeout=1)
        sys.exit(0)
    except Exception:
        time.sleep(0.5)
print("Server did not start in time", file=sys.stderr)
sys.exit(1)
EOF

echo "Server ready. Running Lua tests..."
JUPYTER_TEST_URL="$URL" nvim --headless -u NONE -l tests/test_manager.lua
EXIT=$?

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

exit $EXIT
