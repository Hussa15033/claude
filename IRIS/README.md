# IRIS — Run, Compile & Test the DTL Interfaces

This folder is the **operator's control panel** for the GenAI DTL framework. Behind
everything here is the IRIS interoperability production `DTL.Setup.Production`
(business service → orchestration process → LLM operation) that generates,
compiles, and verifies HL7 v2 Data Transformations. These scripts and snippets
let you **run**, **compile**, and **test** the whole thing without memorising the
internals.

```
                    ┌─────────────── you are here (IRIS/) ───────────────┐
   compile.sh ─┐    │  wraps →  DTL.Setup.Installer  (load+compile+wire)  │
   run.sh ─────┼──► │           DTL.Setup.Production (the 3 hosts)        │
   test.sh ────┘    │           DTL.Test.HealthCheck (init test hook)     │
                    └────────────────────────────────────────────────────┘
        UI  http://localhost:52773/dtl/ui/index.html
        API http://localhost:52773/dtl/api/{health,schemas,generate,jobs}
```

> **Prerequisites:** Docker, and the IRIS for Health Community image
> (`intersystemsdc/irishealth-community:latest`). The scripts create/reuse a
> container named `iris-dtl`. Default IRIS credentials: **SuperUser / SYS**
> (the web apps are configured for unauthenticated access for the demo).

---

## TL;DR — one command

From the **project root** (the parent of this folder):

```bash
scripts/demo.sh            # bring up IRIS, compile, start production + mock, run sample jobs
```

Then open the UI: **http://localhost:52773/dtl/ui/index.html**

Everything below is the same thing, broken into the three verbs you asked for.

---

## 1 · Compile

Loads every framework class from source and compiles it (the bootstrap compile +
the Installer). Use this after editing any `.cls` file.

```bash
IRIS/compile.sh            # [container]  default: iris-dtl
```

> **Incremental only.** `compile.sh` adds/updates classes but does **not** evict
> compiled code for members or classes you *deleted* from source. If you removed a
> property/method or a whole `.cls`, run `IRIS/run.sh` instead — it purges `DTL.*`
> (keeping data) for a clean-slate recompile. See **Clean-slate recompile** under
> §2 · Run.

What it does: `scripts/sync.sh` copies `src/` into the container, then runs
`$system.OBJ.LoadDir(...)` followed by `DTL.Setup.Installer.Run(srcDir, 0)`
(load + prepare dirs + wire web apps, **without** starting the production).

Manual equivalent (inside the container):

```objectscript
zn "USER"
do $system.OBJ.LoadDir("/home/irisowner/dtlsrc/DTL","ck/recurse=1",.err,1)
do ##class(DTL.Setup.Installer).Run("/home/irisowner/dtlsrc", 0)   ; 0 = don't start
```

---

## 2 · Run

Starts the production + the offline mock LLM, then serves the UI and REST API.

```bash
IRIS/run.sh                # [container]  default: iris-dtl
```

What it does: ensures the container is up and healthy, syncs sources, starts the
mock LLM on `:8085`, **purges the framework code for a clean-slate recompile**,
runs `DTL.Setup.Installer.Run(srcDir, 1)` (the `1` starts the production), and
prints the UI/API URLs.

### Clean-slate recompile (why `run.sh` purges first)

`$system.OBJ.LoadDir` only **adds/updates** classes from source — it can never
*remove* stale compiled code. So two things would otherwise linger forever and
break at runtime:

- a **member deleted from a class** (e.g. a property removed in a refactor) stays
  in the compiled class and throws `<PROPERTY DOES NOT EXIST>` when old code paths
  touch it;
- a **whole `.cls` deleted from source** leaves its compiled class behind.

To guarantee that every `IRIS/run.sh` is a from-scratch recompile that can't be
poisoned by old code, step 4 first runs:

```objectscript
do $system.OBJ.Delete("DTL.*","-d/deleteextent=0")   ; delete CODE, keep DATA
do $system.OBJ.LoadDir(dtl_"/DTL","ck/recurse=1",.err,1)   ; reload from source
```

`/deleteextent=0` deletes only the **code** (class definitions + compiled
artifacts); it does **not** touch the persistent **data**. The `^DTL.Data.*`
globals for `SpecDoc` and `Job` survive untouched — those classes carry an
explicit `Storage` map in source, so the reload restores the identical storage
layout and existing rows (saved specs, prior jobs) remain readable. Generated
transforms in `DTL.Generated.*` are not touched either (they're regenerated on
demand). This is verified on every run: data row counts are unchanged and the
health hook reports `8/8`.

> Use `IRIS/compile.sh` for a fast **incremental** compile while editing; use
> `IRIS/run.sh` when you've **deleted** a member/class and need the stale compiled
> artifact gone.

Manual equivalents:

```objectscript
; start the production
do ##class(Ens.Director).StartProduction("DTL.Setup.Production")
; stop it
do ##class(Ens.Director).StopProduction(10, 1)
; generate a DTL for a built-in example pair, straight from the terminal
do ##class(DTL.Setup.Installer).ForgeExample("ADT_A01_Admit", , 5, "CompileMatch")
```

**Drive it from the UI:** open `http://localhost:52773/dtl/ui/index.html`, paste an
input spec + one or more input/output sample pairs, choose the **provider**
(OpenAI / Mock), enter your **OpenAI API key** and pick a **model** (⟳ loads them
live), then click **Generate DTL**. Progress streams in attempt-by-attempt, the
diff viewer shows expected vs the generated DTL's actual output, and the links bar
deep-links to the **IRIS Production page** and the job's **Visual Trace**.

**Drive it from the REST API:**

```bash
# start a job
curl -s http://localhost:52773/dtl/api/generate -H 'Content-Type: application/json' -d '{
  "inputName":"ADT_A01_Admit",
  "inputSpec":"Rename EPICADT->EPIC, SITEA->001, bump 2.3->2.5",
  "maxAttempts":5,"successPolicy":"CompileMatch",
  "pairs":[{"input":"MSH|...","output":"MSH|..."}]
}'
# -> {"jobId":"<id>","status":"QUEUED"}

curl -s http://localhost:52773/dtl/api/jobs/<id>        # poll live status + attempts + diff
curl -s http://localhost:52773/dtl/api/jobs/<id>/dtl    # the final generated DTL class
```

---

## 3 · Test

Runs the **initialization test hook** (`DTL.Test.HealthCheck`) plus the unit /
mock / security suites. This is the "ensure all components of IRIS have been
initialised correctly" check.

```bash
IRIS/test.sh               # [container]  default: iris-dtl
```

It runs, in order:

| Suite | What it proves |
|---|---|
| `DTL.Test.HealthCheck.Run()` | **Init test hook** — classes compiled, production running with all items, LLM endpoint reachable, HL7 schemas installed, `/dtl/api` + `/dtl/ui` registered, data dirs present, and a live compile+transform smoke test. Also exposed at `GET /dtl/api/health`. |
| `DTL.Test.UtilTest.RunAll()` | Verifier / Extractor / DocType derivation against the reference DTLs. |
| `DTL.Test.MockTest.RunAll()` | The mock's broken→wrong→correct self-correction curriculum. |
| `DTL.Test.SecurityTest.RunAll()` | LLM code-injection is neutralized; generated classes are confined to `DTL.Generated.*`. |

A green run ends with `ALL CHECKS PASSED (8/8)` and `ALL EXAMPLE PAIRS PASS`.

You can also hit the hook over HTTP at any time:

```bash
curl -s http://localhost:52773/dtl/api/health | python3 -m json.tool
```

---

## Where things live (in the container)

| Thing | Location |
|---|---|
| Framework source (synced) | `$HOME/dtlsrc/` (e.g. `/home/irisowner/dtlsrc`) |
| Runtime data (derived) | `<iris-mgr>/dtldata/` → `inputs/ outputs/ archive/ results/` |
| Generated DTL artifacts | `<iris-mgr>/dtldata/results/*.dtl.cls` + `*.result.json` |
| Deployed SPA | `<iris-mgr>/csp/dtlui/index.html` |
| Generated DTL classes | the `DTL.Generated.*` package in the USER namespace |

Find the data dir any time: `write ##class(DTL.Setup.Installer).DataDir()`

---

## Switching to the real OpenAI API

The production defaults to the offline mock. To use OpenAI (see the project
README for full steps): set the `DTL.Op.LLMConnector` settings `Mode=openai`,
`ApiKeyCredentials=<cred>`, and the adapter `HTTPServer=api.openai.com`,
`HTTPPort=443`, `SSLConfig=<ssl>`. No code change required.
