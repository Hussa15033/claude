#!/usr/bin/env bash
#
# RUN the DTL framework: ensure the IRIS container is up, sync + compile sources,
# start the offline mock LLM, start the production, and create the web apps.
# Prints the UI and REST API URLs. Behind the scenes this runs the IRIS
# production DTL.Setup.Production.
#
# Usage: IRIS/run.sh [container-name]
#
# CLEAN-SLATE COMPILE (why step 4 purges before it loads):
#   $system.OBJ.LoadDir only ADDS/UPDATES classes from source. On its own it can
#   NEVER remove stale compiled artifacts:
#     - a class member deleted from a .cls (e.g. a property removed in a refactor)
#       lingers in the COMPILED class and throws at runtime
#       (<PROPERTY DOES NOT EXIST> ...), and
#     - a whole .cls deleted from source leaves its compiled class behind forever.
#   So before reloading we DELETE the entire DTL.* package (definitions + compiled)
#   with /deleteextent=0, which removes all framework CODE but PRESERVES persistent
#   DATA (the ^DTL.Data.* globals for SpecDoc/Job survive — those classes carry an
#   explicit Storage map in source, so the reload restores the identical layout and
#   the existing rows are immediately readable). Net effect: every IRIS/run.sh is a
#   from-scratch recompile that can't be poisoned by old code. Generated transforms
#   (DTL.Generated.*) are NOT touched — they are regenerated on demand.
#
#   We also STOP the production before the purge and only re-START it via the
#   Installer afterwards. This matters for the BUSINESS OPERATIONS, which run as
#   long-lived pool jobs (DTL.Op.LLMConnector has PoolSize>1). If the production is
#   left running across a recompile, those jobs keep executing the PREVIOUS compiled
#   version until they happen to recycle (IRIS logs "Host Class ... has been
#   recompiled; continuing to run using code from previous version") — so requests
#   intermittently hit old code depending on which job serves them. A clean
#   stop-then-start forces every job onto the freshly compiled code.
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

# 4. STOP the production, PURGE stale framework code, then bootstrap compile +
#    install + START the production fresh (the 1 starts it). The stop+start is what
#    guarantees the LLMConnector pool jobs (PoolSize>1) pick up the NEW code: a
#    running production only gets *updated* by Installer.Run, which leaves jobs
#    whose class changed running the PREVIOUS compiled version (IRIS logs "Host
#    Class ... has been recompiled; continuing to run using code from previous
#    version") -- the cause of intermittent, version-dependent failures. The purge
#    then guarantees a clean-slate recompile (see the CLEAN-SLATE COMPILE note in
#    this file's header). Resolve the DTL dir to whichever layout docker cp produced
#    ($SRC/DTL or a nested $SRC/src/DTL) so the bootstrap LoadDir can't miss it.
say "Stopping production + purging stale framework code (keeps data) + compiling + starting production"
docker exec -i "$CTR" bash -lc "iris session IRIS -U USER" <<OS
set src="$SRC"
set dtl=\$select(##class(%File).DirectoryExists(src_"/DTL"):src, 1:src_"/src")
// --- Stop the production FIRST so every pool job (esp. DTL.Op.LLMConnector, which
//     runs PoolSize>1) releases its in-memory compiled code. Without this, a
//     recompile leaves running jobs on the OLD version until they happen to recycle
//     -- producing intermittent failures that depend on which job served a request.
//     StopProduction(timeout,force); harmless no-op if nothing is running.
set sc=##class(Ens.Director).StopProduction(20, 1)
write "stop production: ok=",(##class(%SYSTEM.Status).IsOK(sc)),!
// --- Clean slate: delete ALL framework CODE (definition + compiled) but KEEP
//     persistent DATA. /deleteextent=0 leaves the ^DTL.Data.* globals untouched;
//     the reload below restores the storage maps so existing rows stay readable.
//     This removes any member/class that no longer exists in source so nothing
//     stale can survive (the cause of <PROPERTY DOES NOT EXIST> at runtime).
//     Delete on a fresh container with no DTL.* classes is a harmless no-op.
//     (Keep each statement on ONE line: in iris-session terminal mode every line
//     runs independently, so a multi-line brace block fails with SYNTAX. Also
//     avoid shell metachars in these comments -- this heredoc is UNQUOTED so $SRC
//     expands, which means backticks here would be run as a shell command.)
set sc=\$system.OBJ.Delete("DTL.*","-d/deleteextent=0/displaylog=0/displayerror=0")
write "purge DTL.* (code only, data kept): ok=",(##class(%SYSTEM.Status).IsOK(sc)),!
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
