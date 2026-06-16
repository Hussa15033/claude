# IRIS — Run, Compile & Test the DTL Framework

This folder is the **operator's control panel** for the GenAI DTL framework. Behind
everything here is the IRIS interoperability production `DTL.Setup.Production` that
generates, compiles, and **schema-validates** HL7 v2 Data Transformations from a
written **specification** — not from sample messages. These scripts and snippets let
you **run**, **compile**, and **test** the whole thing without memorising the
internals.

```
                    ┌─────────────── you are here (IRIS/) ───────────────┐
   compile.sh ─┐    │  wraps →  DTL.Setup.Installer  (load+compile+wire)  │
   run.sh ─────┼──► │           DTL.Setup.Production (the production)     │
   test.sh ────┘    │           DTL.Test.HealthCheck (init test hook)     │
                    └────────────────────────────────────────────────────┘
        UI  http://localhost:52773/dtl/ui/index.html
        API http://localhost:52773/dtl/api/{health,schemas,projects,jobs}
```

> **Prerequisites:** Docker, and the IRIS for Health Community image
> (`intersystemsdc/irishealth-community:latest`). The scripts create/reuse a
> container named `iris-dtl`. Default IRIS credentials: **SuperUser / SYS**
> (the web apps are configured for unauthenticated access for the demo).

> Verified running live against **IRIS for Health 2026.1**, end to end, against the
> built-in offline mock LLM (no API key required), and against AWS Bedrock
> (Anthropic Claude) and OpenAI.

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
globals for `Project`, `SpecDoc`, and `Job` survive untouched — those classes
carry an explicit `Storage` map in source, so the reload restores the identical
storage layout and existing rows (saved projects, specs, prior jobs) remain
readable. Generated transforms in `DTL.Generated.*` are not touched either
(they're regenerated on demand). This is verified on every run: data row counts
are unchanged and the health hook reports `8/8`.

> Use `IRIS/compile.sh` for a fast **incremental** compile while editing; use
> `IRIS/run.sh` when you've **deleted** a member/class and need the stale compiled
> artifact gone.

Manual equivalents:

```objectscript
; start the production
do ##class(Ens.Director).StartProduction("DTL.Setup.Production")
; stop it
do ##class(Ens.Director).StopProduction(10, 1)
```

**Drive it from the UI:** open `http://localhost:52773/dtl/ui/index.html`. Create a
**project** (fixing one HL7 version), **upload** a specification document and
**approve** its concise spec, let the project **derive the message types** the spec
covers, **tick** the ones to build, and click **Generate** — one reviewed DTL per
type, fanned out concurrently. No sample messages are required: the framework
synthesises schema-valid test messages itself. Review each DTL (gate verdict, DTL
source, synthetic + any of your own messages with their schema-validity badge),
send live messages through it, then **export** all DTLs as one XML or keep them as
the compiled `DTL.Generated.*` package. Pick the **provider** (OpenAI / Bedrock /
Mock) and enter the **API key** per job in Settings.

**Drive it from the REST API** (project-oriented):

```bash
# 1. create a project (fixes the HL7 version for every transform in it)
curl -s http://localhost:52773/dtl/api/projects -H 'Content-Type: application/json' -d '{
  "name":"Lab Interface","hl7Version":"2.5","provider":"mock"
}'
# -> {"token":"<tok>", ...}

# 2. attach a spec already uploaded + approved (POST /upload then approve-concise)
curl -s http://localhost:52773/dtl/api/projects/<tok>/specs \
  -H 'Content-Type: application/json' -d '{"specToken":"<specTok>"}'

# 3. see the message types the approved specs cover
curl -s http://localhost:52773/dtl/api/projects/<tok>/types

# 4. lock the specs and generate one child job per selected type
curl -s http://localhost:52773/dtl/api/projects/<tok>/generate \
  -H 'Content-Type: application/json' -d '{"types":["2.5:ORU_R01"]}'

# 5. poll the project until every child job settles
curl -s http://localhost:52773/dtl/api/projects/<tok>

# 6. download all generated DTLs as one importable XML
curl -s http://localhost:52773/dtl/api/projects/<tok>/export > project-dtls.xml
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
| `DTL.Test.UtilTest.RunAll()` | Verifier / Extractor / SampleGen / SchemaValidate / DocType derivation against the reference DTLs. |
| `DTL.Test.MockTest.RunAll()` | The mock's broken→wrong→correct self-correction curriculum. |
| `DTL.Test.SecurityTest.RunAll()` | LLM code-injection is neutralized; generated classes are confined to `DTL.Generated.*`. |

A green run ends with the health hook reporting `8/8` and the MockTest
broken→wrong→correct curriculum passing.

You can also hit the hook over HTTP at any time:

```bash
curl -s http://localhost:52773/dtl/api/health | python3 -m json.tool
```

---

## The production hosts

Everything enters through a real Business Service and flows through the production,
so every message is visible in the **Visual Trace** (no detached jobs, no test
harnesses used as entry points).

| Host | Kind | Role |
|---|---|---|
| `DTL.Svc.ApiService` | Business **Service** | The single, adapterless inbound boundary; typed methods so every REST-driven call is traced. (Replaced the old `EnsLib.Testing.Service` misuse.) |
| `DTL.Svc.SpecFileService` | Business **Service** | File-drop intake for spec documents. |
| `DTL.Svc.PairFileService` | Business **Service** | File-drop intake for sample messages. |
| `DTL.Proc.SpecForge` | Business **Process** | Durable-queue worker that generates + verifies the concise spec. |
| `DTL.Proc.Orchestrator` | Business **Process** | The ungated generate→compile→run→verify→regenerate loop (file-drop / test flows). |
| `DTL.Op.LLMConnector` | Business **Operation** | OpenAI-compatible chat completions over HTTP (OpenAI / AWS Bedrock / mock). |

The gated, step-by-step build (the UI's default) is driven by
`DTL.Service.StepEngine`; `DTL.Service.ProjectManager` owns project lifecycle
(create, attach specs, derive types, assemble per-type specs, fan out child jobs,
export XML); `DTL.Service.JobManager` bridges REST → production.

---

## Where things live (in the container)

| Thing | Location |
|---|---|
| Framework source (synced) | `$HOME/dtlsrc/` (e.g. `/home/irisowner/dtlsrc`) |
| Runtime data (derived) | `<iris-mgr>/dtldata/` → `inputs/ outputs/ archive/ results/` |
| Generated DTL artifacts | `<iris-mgr>/dtldata/results/*.dtl.cls` + `*.result.json` |
| Deployed SPA | `<iris-mgr>/csp/dtlui/index.html` |
| Project records | `^DTL.Data.Project*` globals (USER namespace) |
| Uploaded-spec records | `^DTL.Data.SpecDoc*` globals (USER namespace) |
| Job + per-attempt records | `^DTL.Data.Job*` globals (USER namespace) |
| Generated DTL classes | the `DTL.Generated.*` package in the USER namespace |

Find the data dir any time: `write ##class(DTL.Setup.Installer).DataDir()`

---

## LLM provider — OpenAI · AWS Bedrock · Mock

The mock and the live providers use the **identical wire format**
(`POST /v1/chat/completions`). The API key is entered in the **UI Settings** and
sent **per request** to your same-origin IRIS server, used for that job/project
only, and is **never** written to the Job record or logs.

`IRIS/run.sh` starts the offline mock automatically for key-free demos/CI. The
production default `Mode` in `DTL.Setup.Production` is `openai`, but the UI lets you
pick the provider per job/project. The installer creates the `DTLOpenAISSL` TLS
configuration so HTTPS to `api.openai.com` works out of the box; see the project
README for the full provider walkthrough.
