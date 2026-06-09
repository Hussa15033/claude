#!/usr/bin/env bash
# Sync the src/ tree (and example data) into the IRIS container.
#
# Paths are NOT hardcoded:
#   - the project root is derived from this script's own location (relative),
#   - the in-container destination is derived from the container's $HOME at runtime
#     (falls back to /home/irisowner only if $HOME is somehow unset).
#
# Usage: scripts/sync.sh [container-name]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # project root, relative to this file
CTR="${1:-iris-dtl}"

# Resolve the container's default (non-root) user and home dir, and place sources
# under $HOME/dtlsrc. IRIS runs as this user, so the synced files must be owned by
# and readable by it -- docker cp runs as root and can leave root-owned 0600 files.
# `tr -d '\r'` guards against a CRLF-checked-out caller passing a stray carriage
# return into these values (which would corrupt the DEST path -> #5007 in IRIS).
CUSER="$(docker exec "$CTR" bash -lc 'printf %s "$(id -un)"' | tr -d '\r')"
CGROUP="$(docker exec "$CTR" bash -lc 'printf %s "$(id -gn)"' | tr -d '\r')"
CHOME="$(docker exec "$CTR" bash -lc 'printf %s "${HOME:-/home/irisowner}"' | tr -d '\r')"
DEST="$CHOME/dtlsrc"

# (Re)create the destination.
docker exec "$CTR" bash -lc "rm -rf '$DEST' && mkdir -p '$DEST'" 2>/dev/null || \
  docker exec -u root "$CTR" bash -lc "rm -rf '$DEST' && mkdir -p '$DEST'"

# Copy each item as a NAMED directory (no trailing '/.' trick). On Windows/Git Bash
# a "src/." source gets mangled, copying 'src' as a nested folder so the tree lands
# at $DEST/src/DTL instead of $DEST/DTL (-> IRIS #5007). Copying $HERE/src/DTL
# straight to $DEST/ puts DTL exactly where LoadDir expects it, on every platform.
docker cp "$HERE/src/DTL"   "$CTR:$DEST/"          # -> $DEST/DTL  (the classes)
docker cp "$HERE/inputs"    "$CTR:$DEST/inputs"
docker cp "$HERE/outputs"   "$CTR:$DEST/outputs"
docker cp "$HERE/reference" "$CTR:$DEST/reference" 2>/dev/null || true
docker cp "$HERE/ui"        "$CTR:$DEST/ui" 2>/dev/null || true
docker cp "$HERE/mock"      "$CTR:$DEST/mock" 2>/dev/null || true   # holds dtl_extract.py (doc extraction helper)

# Safety net: if any 'src/.'-style artifact ever nests the tree, flatten it up so
# $DEST/DTL is always present regardless of how docker cp behaved on this host.
docker exec "$CTR" bash -lc "[ -d '$DEST/src/DTL' ] && cp -a '$DEST/src/.' '$DEST/' && rm -rf '$DEST/src' || true" 2>/dev/null || true

# Make everything owned by and readable by the IRIS user (fixes root-owned 0600
# files left by docker cp, which otherwise cause <Cannot open file> on compile).
docker exec -u root "$CTR" bash -lc "chown -R '$CUSER:$CGROUP' '$DEST' && chmod -R u+rwX,go+rX '$DEST'"

echo "synced $HERE/src -> $CTR:$DEST (owner $CUSER:$CGROUP)"
