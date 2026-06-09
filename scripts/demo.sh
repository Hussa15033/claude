#!/usr/bin/env bash
#
# End-to-end demo of the DTL GenAI framework.
#
# Spins up (or reuses) an IRIS for Health container, loads the framework, starts
# the mock LLM + the production, and runs a forge job for each example pair --
# proving the generate -> compile -> verify -> regenerate loop converges on a
# correct, compiling DTL with NO OpenAI API key required.
#
# Paths are not hardcoded: the project root is taken from this script's location,
# and the in-container source dir is derived from the container's $HOME.
#
# Usage:  scripts/demo.sh [container-name]
#
# Windows note: if you hit "#5007 directory invalid" or "syntax error near do\r",
# your .sh files are CRLF; fix once: find . -name '*.sh' -exec sed -i 's/\r$//' {} \;
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTR="${1:-iris-dtl}"
IMAGE="intersystemsdc/irishealth-community:latest"

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

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

# 2. Sync sources into the container (dest derived from container $HOME).
say "Syncing framework sources"
bash "$HERE/scripts/sync.sh" "$CTR"
CHOME="$(docker exec "$CTR" bash -lc 'printf %s "${HOME:-/home/irisowner}"' | tr -d '\r')"
SRC="$CHOME/dtlsrc"
docker cp "$HERE/mock/mock_llm.py" "$CTR:$CHOME/mock_llm.py"

# 3. Start the mock LLM (robust, idempotent — see scripts/mock.sh).
say "Starting mock LLM on :8085"
bash "$HERE/scripts/mock.sh" "$CTR" 8085

# 4. BOOTSTRAP: compile the framework (incl. the Installer) BEFORE calling it,
#    then install (prepare dirs + wire derived paths + start) and run the jobs.
#    This bootstrap compile is essential -- the Installer cannot load itself.
say "Compiling framework + installing + running forge jobs"
docker exec -i "$CTR" bash -lc "iris session IRIS -U USER" <<OS
set src="$SRC"
set dtl=\$select(##class(%File).DirectoryExists(src_"/DTL"):src, 1:src_"/src")
set sc=\$system.OBJ.LoadDir(dtl_"/DTL","ck/displayerror=0/displaylog=0/recurse=1",.err,1)
if 'sc { write "BOOTSTRAP COMPILE FAILED: ",\$system.Status.GetErrorText(sc),! halt }
write "bootstrap compile OK",!
do ##class(DTL.Setup.Installer).Run(dtl,1)
write !,"==== FORGE JOBS (max 5 attempts, policy CompileMatch) ====",!
do ##class(DTL.Setup.Installer).ForgeExample("ADT_A01_Admit",dtl,5,"CompileMatch")
do ##class(DTL.Setup.Installer).ForgeExample("ADT_A08_Update",dtl,5,"CompileMatch")
do ##class(DTL.Setup.Installer).ForgeExample("ORU_R01_LabResult",dtl,5,"CompileMatch")
halt
OS

# 5. Show the generated artifacts (data dir is under the IRIS manager directory).
say "Generated artifacts"
docker exec -i "$CTR" bash -lc "iris session IRIS -U USER" <<'OS'
set d=##class(DTL.Setup.Installer).DataDir()_"results"
write "results dir: ",d,!
set rs=##class(%ResultSet).%New("%File:FileSet")
do rs.Execute(d,"*")
while rs.Next() { write "  ",##class(%File).GetFilename(rs.GetData(1)),! }
halt
OS
echo "--- mock LLM curriculum (self-correction) ---"
docker exec "$CTR" bash -lc 'tail -12 /tmp/mock.log 2>/dev/null || echo "(mock log not captured in this container session)"'

say "Demo complete"
echo "UI:                http://localhost:52773/dtl/ui/index.html"
echo "Management Portal: http://localhost:52773/csp/sys/UtilHome.csp  (SuperUser / SYS)"
echo "Production: USER namespace -> Interoperability -> DTL.Setup.Production"
