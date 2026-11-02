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

# Load deployment config from .env (host ports, container name, image, password).
# .env is optional; .env.example documents every setting. .env is the source of
# truth (edit it to change ports); the built-in defaults below apply only when a
# setting is absent from .env, and the first CLI arg still overrides the container
# name. To override for a single run without editing .env, pass on the command line,
# e.g.  IRIS_WEB_PORT=8443 ... — note this requires commenting that line out of .env,
# since sourcing .env sets it. (For most users: just edit .env.)
if [ -f "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi
IRIS_WEB_PORT="${IRIS_WEB_PORT:-52773}"
IRIS_SUPERSERVER_PORT="${IRIS_SUPERSERVER_PORT:-1972}"
IRIS_CONTAINER="${IRIS_CONTAINER:-iris-dtl}"
IRIS_IMAGE="${IRIS_IMAGE:-intersystemsdc/irishealth-community:latest}"
IRIS_PASSWORD="${IRIS_PASSWORD:-SYS}"
MOCK_LLM_PORT="${MOCK_LLM_PORT:-8085}"
CTR="${1:-$IRIS_CONTAINER}"
IMAGE="$IRIS_IMAGE"

say(){ printf '\n== %s ==\n' "$*"; }

# 1. Ensure the container exists, is running and healthy; fail loudly (with the
#    container's log tail) otherwise. IRIS always listens on 1972/52773 INSIDE the
#    container; we publish them to the configurable HOST ports above.
#
#    WHY WE BYPASS THE IMAGE'S INIT HOOK:
#      The intersystemsdc/irishealth-community 2026.1 images (rebuilt 2026-09-09) run a
#      first-start hook (docker-entrypoint.sh iris-after-start) that uses irissqlcli
#      -> iris.dbapi.connect. In 2026.1 the DB-API driver is no longer part of the
#      embedded `iris` module (it ships separately as /usr/irissys/dev/python/
#      intersystems_irispython-*.whl, not installed), so the hook dies with
#      "Cannot call an iris.package wrapper ... dbapi.connect" and the entrypoint
#      SHUTS IRIS DOWN -- the container exits(1) on first start. Installing that wheel
#      into mgr/python is NOT a fix: it shadows the embedded `iris` module and breaks
#      iris.cls(), which DTL.Util.Py relies on.
#      So we start IRIS directly (/iris-main) and do the only parts of that hook we
#      need ourselves: enable %Service_CallIn and set the account passwords. The USER
#      namespace already exists in IRIS for Health, and we have no initdb scripts.
die(){
  echo "ERROR: $*" >&2
  echo "--- last container log lines ---" >&2
  docker logs --tail 15 "$CTR" >&2 2>&1 || true
  exit 1
}

CREATED=0
# A container created by an older run.sh under Git Bash got a Windows-mangled
# entrypoint (e.g. "C:/Program Files/Git/tini") and can never start. It never ran,
# so it holds no data -- say so plainly instead of failing with an OCI error.
if docker ps -a --format '{{.Names}}' | grep -qx "$CTR" \
   && docker inspect --format '{{json .Config.Entrypoint}}' "$CTR" 2>/dev/null | grep -qE '[A-Za-z]:/'; then
  echo "ERROR: container '$CTR' was created with a Windows-mangled entrypoint ($(docker inspect --format '{{json .Config.Entrypoint}}' "$CTR"))." >&2
  echo "It never started and holds no data; remove it and re-run:   docker rm $CTR" >&2
  exit 1
fi

if ! docker ps -a --format '{{.Names}}' | grep -qx "$CTR"; then
  say "Starting IRIS for Health container '$CTR' (host ports ${IRIS_WEB_PORT}->52773, ${IRIS_SUPERSERVER_PORT}->1972)"
  # MSYS_NO_PATHCONV / MSYS2_ARG_CONV_EXCL: on Windows Git Bash, stop MSYS rewriting
  # the in-container paths /tini and /iris-main into "C:/Program Files/Git/...".
  # Ignored on Linux/macOS.
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker run -d --name "$CTR" \
    -p "${IRIS_SUPERSERVER_PORT}:1972" -p "${IRIS_WEB_PORT}:52773" \
    --entrypoint /tini "$IMAGE" -- /iris-main --ISCAgent false >/dev/null
  CREATED=1
fi

if ! docker start "$CTR" >/dev/null 2>&1 \
   || ! [ "$(docker inspect --format '{{.State.Running}}' "$CTR")" = "true" ]; then
  if docker logs "$CTR" 2>&1 | grep -q "Error executing post-startup command"; then
    die "container '$CTR' was created with the image's broken init hook and never initialised.
It holds no data; remove it and re-run:   docker rm $CTR"
  fi
  die "container '$CTR' would not start"
fi

say "Waiting for IRIS to be healthy"
for i in $(seq 1 40); do
  st="$(docker inspect --format '{{.State.Health.Status}}' "$CTR" 2>/dev/null || echo none)"
  [ "$st" = "healthy" ] && break
  [ "$(docker inspect --format '{{.State.Running}}' "$CTR")" = "true" ] || die "container '$CTR' exited while starting"
  sleep 5
done
[ "$st" = "healthy" ] || die "IRIS in '$CTR' not healthy after 200s (status: $st)"
echo "healthy"

# First-start init (replaces the image hook -- see above). Only on create, so a
# password you later change in the Portal isn't reset on every run. The password
# is passed via the environment so no quoting can break the session script.
if [ "$CREATED" = 1 ]; then
  say "Initialising instance (CallIn + passwords)"
  docker exec -i -e DTL_PW="$IRIS_PASSWORD" "$CTR" iris session IRIS -U%SYS <<'OS'
set pw=$SYSTEM.Util.GetEnviron("DTL_PW")
set prop("Enabled")=1 set sc=##class(Security.Services).Modify("%Service_CallIn",.prop) write "callin: ok=",+sc,!
kill prop set prop("Password")=pw,prop("ChangePassword")=0,prop("PasswordNeverExpires")=1
for u="SuperUser","_SYSTEM","Admin" set sc=##class(Security.Users).Modify(u,.prop) write "password ",u,": ok=",+sc,!
halt
OS
fi

# 2. Sync sources.
say "Syncing sources"
bash "$HERE/scripts/sync.sh" "$CTR"
CHOME="$(docker exec "$CTR" bash -lc 'printf %s "${HOME:-/home/irisowner}"' | tr -d '\r')"
SRC="$CHOME/dtlsrc"

# 3. Start the mock LLM (robust, idempotent — see scripts/mock.sh). Runs INSIDE the
#    container; the production connects to it on this port via localhost.
say "Starting mock LLM on :${MOCK_LLM_PORT}"
bash "$HERE/scripts/mock.sh" "$CTR" "$MOCK_LLM_PORT"

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

# 5. Show URLs. Prefer the actually-published host port (handles a pre-existing
#    container mapped differently); fall back to the configured IRIS_WEB_PORT.
PORT="$(docker port "$CTR" 52773/tcp 2>/dev/null | head -1 | sed 's/.*://')"; PORT="${PORT:-$IRIS_WEB_PORT}"
say "Ready"
echo "UI:     http://localhost:${PORT}/dtl/ui/index.html"
echo "API:    http://localhost:${PORT}/dtl/api/health   (init/health check)"
echo "Portal: http://localhost:${PORT}/csp/sys/UtilHome.csp   (SuperUser / SYS)"
echo "Production: USER namespace -> Interoperability -> DTL.Setup.Production"
