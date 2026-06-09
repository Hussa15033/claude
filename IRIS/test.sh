#!/usr/bin/env bash
#
# TEST the DTL framework: run the initialization test hook (DTL.Test.HealthCheck)
# plus the unit / mock / security suites. Use this to confirm every IRIS
# component has been initialised correctly.
#
# Assumes the framework is already compiled and running (IRIS/run.sh). It will
# sync + compile first so it is safe to run standalone.
#
# Usage: IRIS/test.sh [container-name]
#
# Windows note: if you hit "#5007 directory invalid" or "syntax error near do\r",
# your .sh files are CRLF; fix once: find . -name '*.sh' -exec sed -i 's/\r$//' {} \;
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTR="${1:-iris-dtl}"

echo "== Test: syncing + compiling =="
bash "$HERE/scripts/sync.sh" "$CTR" >/dev/null
SRC="$(docker exec "$CTR" bash -lc 'printf %s "${HOME:-/home/irisowner}"' | tr -d '\r')/dtlsrc"
# Make sure the mock + production are up so the health hook has something to check.
bash "$HERE/scripts/mock.sh" "$CTR" 8085 || true

docker exec -i "$CTR" bash -lc "iris session IRIS -U USER" <<OS
set src="$SRC"
set dtl=\$select(##class(%File).DirectoryExists(src_"/DTL"):src, 1:src_"/src")
set sc=\$system.OBJ.LoadDir(dtl_"/DTL","ck/displayerror=0/displaylog=0/recurse=1",.err,1)
if 'sc { write "COMPILE FAILED: ",\$system.Status.GetErrorText(sc),! halt }
do ##class(DTL.Setup.Installer).Run(dtl, 1)
write !,"############ 1. INIT / HEALTH TEST HOOK ############",!
set ok=##class(DTL.Test.HealthCheck).Run()
write !,"############ 2. UTIL TESTS ############",!
do ##class(DTL.Test.UtilTest).RunAll()
write !,"############ 3. MOCK CURRICULUM TESTS ############",!
do ##class(DTL.Test.MockTest).RunAll()
write !,"############ 4. SECURITY TESTS ############",!
do ##class(DTL.Test.SecurityTest).RunAll()
write !,"############ HEALTH HOOK RESULT: ",\$select(ok:"PASS",1:"FAIL")," ############",!
halt
OS

echo ""
echo "== Test: also verifying the health hook over HTTP =="
docker exec "$CTR" bash -lc "python3 - <<'PY'
import urllib.request, json
try:
    d = json.loads(urllib.request.urlopen('http://localhost:8085/health', timeout=3).read())
except Exception:
    pass
try:
    d = json.loads(urllib.request.urlopen('http://localhost:52773/dtl/api/health', timeout=8).read())
    print('  GET /dtl/api/health -> ok=%s (%d/%d checks)' % (d['ok'], d['passed'], d['total']))
except Exception as e:
    print('  GET /dtl/api/health ->', type(e).__name__, str(e)[:120])
PY"
