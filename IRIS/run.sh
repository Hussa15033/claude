#!/usr/bin/env bash
#
# RUN the DTL framework: ensure the IRIS container is up, sync + compile sources,
# start the offline mock LLM, start the production, and create the web apps.
# Prints the UI and REST API URLs. Behind the scenes this runs the IRIS
# production DTL.Setup.Production.
#
# Usage: IRIS/run.sh [container-name]
#
# NOTE (Windows): if you see "#5007 ... directory invalid" or "syntax error near
# `do\r`", your .sh files have CRLF line endings. Fix once with:
#     find . -name '*.sh' -exec sed -i 's/\r$//' {} \;
# (The bundled .gitattributes keeps .sh as LF on a fresh checkout.)
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTR="${1:-iris-dtl}"
IMAGE="intersystemsdc/irishealth-community:latest"

say(){ printf '\n== %s ==\n' "$*"; }

# 1. Ensure the container exists and is healthy.
if ! docker ps -a --format '{{.Names}}' | grep -qx "$CTR"; then
  say "Starting IRIS for Health container '$CTR'"
  docker run -d --name "$CTR" -p 1972:1972 -p 52773:52773 -e IRIS_PASSWORD=SYS "$IMAGE" >/dev/null
fi
docker start "$CTR" >/dev/null 2>&1 || true
say "Waiting for IRIS to be healthy"
for i in $(seq 1 40); do
  st="$(docker inspect --format '{{.State.Health.Status}}' "$CTR" 2>/dev/null || echo none)"
  [ "$st" = "healthy" ] && { echo "healthy"; break; }
  sleep 5
done

# 2. Sync sources + deploy mock.
say "Syncing sources"
bash "$HERE/scripts/sync.sh" "$CTR"
CHOME="$(docker exec "$CTR" bash -lc 'printf %s "${HOME:-/home/irisowner}"' | tr -d '\r')"
SRC="$CHOME/dtlsrc"
docker cp "$HERE/mock/mock_llm.py" "$CTR:$CHOME/mock_llm.py"

# 3. Start the mock LLM (robust, idempotent — see scripts/mock.sh).
say "Starting mock LLM on :8085"
bash "$HERE/scripts/mock.sh" "$CTR" 8085

# 3a. Document-extraction libraries (pypdf, python-docx) are installed by the
#     installer (DTL.Setup.Installer.Run -> DTL.Util.Py.EnsurePackages), which
#     discovers the embedded-python interpreter + IRIS package dir cross-OS and
#     installs into <mgr>/python. Nothing to do here.

# 4. Bootstrap compile + install + START the production (the 1 starts it).
#    Resolve the DTL dir to whichever layout docker cp produced ($SRC/DTL or a
#    nested $SRC/src/DTL) so the bootstrap LoadDir can't miss it.
say "Compiling + starting production"
docker exec -i "$CTR" bash -lc "iris session IRIS -U USER" <<OS
set src="$SRC"
set dtl=\$select(##class(%File).DirectoryExists(src_"/DTL"):src, 1:src_"/src")
set sc=\$system.OBJ.LoadDir(dtl_"/DTL","ck/displayerror=0/displaylog=0/recurse=1",.err,1)
if 'sc { write "COMPILE FAILED: ",\$system.Status.GetErrorText(sc),! halt }
do ##class(DTL.Setup.Installer).Run(dtl, 1)
halt
OS

# 5. Show URLs.
PORT="$(docker port "$CTR" 52773/tcp 2>/dev/null | head -1 | sed 's/.*://')"; PORT="${PORT:-52773}"
say "Ready"
echo "UI:     http://localhost:${PORT}/dtl/ui/index.html"
echo "API:    http://localhost:${PORT}/dtl/api/health   (init/health check)"
echo "Portal: http://localhost:${PORT}/csp/sys/UtilHome.csp   (SuperUser / SYS)"
echo "Production: USER namespace -> Interoperability -> DTL.Setup.Production"
