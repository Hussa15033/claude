#!/usr/bin/env bash
# Ensure the offline mock LLM is running and ACCEPTING CONNECTIONS in the
# container, deploying the script if needed. Robust against a stale/dead process
# that still matches pgrep. Called by run.sh / test.sh / demo.sh.
#
# Usage: scripts/mock.sh [container-name] [port]
#
# NOTE: intentionally NOT using `set -e` — the connection probes are expected to
# fail while the server is starting, and we handle their exit codes explicitly.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTR="${1:-iris-dtl}"
PORT="${2:-8085}"
CHOME="$(docker exec "$CTR" bash -lc 'printf %s "${HOME:-/home/irisowner}"' | tr -d '\r')"

# Deploy the mock script (idempotent).
docker cp "$HERE/mock/mock_llm.py" "$CTR:$CHOME/mock_llm.py" >/dev/null 2>&1

# Returns 0 if something is accepting TCP connections on PORT.
probe() {
  docker exec "$CTR" bash -lc "python3 - <<'PY' 2>/dev/null
import socket,sys
s=socket.socket(); s.settimeout(2)
try:
    s.connect(('localhost',$PORT)); s.close(); sys.exit(0)
except Exception:
    sys.exit(1)
PY"
}

if probe; then echo "mock-ready (already up on :$PORT)"; exit 0; fi

# (Re)launch detached. `docker exec -d` + `exec python3` replaces the shell with
# python, re-parenting it to the container init so it persists after this returns.
docker exec "$CTR" bash -lc "pkill -f mock_llm.py 2>/dev/null; touch /tmp/mock.log; exit 0"
docker exec -d "$CTR" bash -lc "exec python3 -u '$CHOME/mock_llm.py' --port $PORT >>/tmp/mock.log 2>&1"

i=0
while [ "$i" -lt 15 ]; do
  if probe; then echo "mock-ready (started on :$PORT)"; exit 0; fi
  i=$((i+1)); sleep 1
done
echo "WARNING: mock LLM did not become reachable on :$PORT" >&2
docker exec "$CTR" bash -lc "tail -5 /tmp/mock.log 2>/dev/null" >&2
exit 1
