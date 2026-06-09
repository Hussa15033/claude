#!/usr/bin/env bash
#
# COMPILE the DTL framework: sync sources into the container and load+compile
# every class (bootstrap compile, then the Installer load with the production
# NOT started). Run after editing any .cls file.
#
# Usage: IRIS/compile.sh [container-name]
#
# Windows note: if you hit "#5007 directory invalid" or "syntax error near do\r",
# your .sh files are CRLF; fix once: find . -name '*.sh' -exec sed -i 's/\r$//' {} \;
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # project root
CTR="${1:-iris-dtl}"

echo "== Compile: syncing sources into $CTR =="
bash "$HERE/scripts/sync.sh" "$CTR"
SRC="$(docker exec "$CTR" bash -lc 'printf %s "${HOME:-/home/irisowner}"' | tr -d '\r')/dtlsrc"

echo "== Compile: bootstrap LoadDir + Installer (load only, no start) =="
docker exec -i "$CTR" bash -lc "iris session IRIS -U USER" <<OS
set src="$SRC"
set dtl=\$select(##class(%File).DirectoryExists(src_"/DTL"):src, 1:src_"/src")
set sc=\$system.OBJ.LoadDir(dtl_"/DTL","ck/displayerror=0/displaylog=0/recurse=1",.err,1)
if 'sc { write "COMPILE FAILED: ",\$system.Status.GetErrorText(sc),! halt }
write "bootstrap compile OK",!
do ##class(DTL.Setup.Installer).Run(dtl, 0)
halt
OS
echo "== Compile done =="
