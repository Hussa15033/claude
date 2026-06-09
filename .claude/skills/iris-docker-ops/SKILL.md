---
name: iris-docker-ops
description: Running, scripting, and recovering an InterSystems IRIS instance in Docker for development. Use when standing up IRIS/IRIS-for-Health containers, executing ObjectScript non-interactively, syncing source into a container, loading/compiling classes, keeping a sidecar process alive, or recovering from a corrupted/locked instance. Covers docker cp path-mangling, CRLF, detached processes, and the "never iris stop" rule.
---

# Running & scripting IRIS in Docker (dev)

Operational recipes for driving an IRIS container from host scripts, plus the
recovery procedures for the failure modes that actually happen.

## Image & startup

- HL7 work needs **IRIS for Health**: `intersystemsdc/irishealth-community:latest`
  (plain `iris-community` lacks `EnsLib.HL7.*`).
- `docker run -d --name iris-dtl -p 1972:1972 -p 52773:52773 -e IRIS_PASSWORD=SYS <image>`
- Wait for healthy: poll `docker inspect --format '{{.State.Health.Status}}'`.
- Default creds: **SuperUser / SYS** (web app at `:52773/csp/sys/UtilHome.csp`).

## Run ObjectScript non-interactively

```bash
docker exec -i <ctr> bash -lc 'iris session IRIS -U USER' <<'OS'
write $zversion,!
halt
OS
```
Remember: the terminal is line-at-a-time — no multi-line `{}` blocks, no `$$$`
macros (see objectscript-gotchas skill). For real logic, load a `.cls` and call it.

## Sync source into the container — avoid `docker cp src/.` (Windows mangles it)

`docker cp "$HERE/src/." dest` works on Linux but on **Windows/Git Bash** MSYS
strips the trailing `/.`, so it copies `src` as a nested dir → tree lands at
`dest/src/DTL` instead of `dest/DTL`. Copy NAMED subdirs instead:
`docker cp "$HERE/src/DTL" "$CTR:$DEST/"`. Make resolvers tolerate both layouts.

After `docker cp`, files are **root-owned 0600** → IRIS (running as `irisowner`)
gets `<Cannot open file>` on compile. Fix:
`docker exec -u root <ctr> bash -lc "chown -R irisowner:irisowner $DEST && chmod -R go+rX $DEST"`.

## CRLF will break your .sh and corrupt paths

A Windows-checked-out `.sh` carries `\r`; `SRC="$CHOME/dtlsrc"` then becomes
`/home/...dtlsrc␍` → IRIS `#5007 directory invalid`, or bash `syntax error near
do\r`. Fixes: ship a `.gitattributes` (`*.sh text eol=lf`), pipe captured
container output through `| tr -d '\r'`, and document the one-liner remedy:
`find . -name '*.sh' -exec sed -i 's/\r$//' {} \;`. An in-file self-heal guard
does NOT work — bash parses the whole CRLF file and fails before reaching it.

## Load + compile a directory of classes

```objectscript
set sc=$system.OBJ.LoadDir("/path/DTL","ck/displayerror=0/displaylog=0/recurse=1",.err,1)
```
Bootstrap trap: an Installer class that LoadDir-compiles the code **cannot load
itself** — run a `LoadDir` once first, then call the installer.

## Keep a sidecar process (mock server, etc.) alive

Plain `&`, `nohup &`, and even `docker exec -d "python …"` can be reaped when the
exec returns or crash on first request. The reliable form:
```bash
docker exec -d <ctr> bash -lc 'exec python3 -u /path/server.py >>/tmp/log 2>&1'
```
`exec` replaces the shell with the program so it re-parents to the container init.
Then poll a TCP connect to confirm it's actually accepting before proceeding.

## Recovery procedures (in order of preference)

1. **Corrupted routine cache** (`<ROUTINELOAD> invalid cache`, after an Embedded
   Python SIGSEGV): `docker restart <ctr>`.
2. **Production won't start** (`ErrProductionNotShutdownCleanly`):
   `##class(Ens.Director).CleanProduction()` then `StartProduction`.
3. **`ErrCanNotAcquireRuntimeLock`** (stuck/half-started production holding
   `^Ens.Runtime`): `docker restart <ctr>`.
4. **Hung CSP gateway** (all HTTP times out but terminal works): `docker restart <ctr>`.
5. **Destroyed namespace** (`<DIRECTORY>` at startup, "Access Denied" to USER,
   missing `IRIS.DAT`): from `%SYS`,
   `##class(SYS.Database).CreateDatabase("/usr/irissys/mgr/user/")` — the namespace
   config + interop-enablement survive; reinstall your source.

## ❌ NEVER `iris stop` / `iris start` manually to recover

Doing so mid-operation **destroyed the USER database** and left auth in a broken
state. Always use `docker restart <ctr>` (runs the proper startup sequence) or the
targeted `Ens.Director` recovery calls above. Keep all source on the host so a
container rebuild loses nothing.
