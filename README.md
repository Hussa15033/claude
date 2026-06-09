# DTL Auto-Generation Framework (GenAI → InterSystems DTL)

A framework that **uses GenAI to write InterSystems IRIS Data Transformation
Language (DTL)** for HL7 v2 interface mappings. You provide an example HL7 v2
*input* message and an example *output* message; an IRIS interoperability
production asks an LLM for a DTL, **compiles it, runs it, verifies the result**
against the expected output, and — if it fails to compile or doesn't match —
feeds the errors/diff back to the LLM and **regenerates**, looping up to a
configurable number of attempts or until it succeeds.

> The whole loop has been verified running in a live **IRIS for Health 2026.1**
> container, end to end, against a built-in offline mock LLM (no OpenAI key
> required). All three example pairs converge to a byte-exact transform.

---

## Why this is non-trivial

Real health-interface example pairs come with a catch the framework is designed
around: **the example output is not guaranteed to be the literal machine
transform of the example input.** The pair illustrates the *kind* of
transformation. So the framework separates *objective* gates (does it compile?
does it run?) from a *reported-but-tunable* match score, and classifies field
differences by whether the expected value is even derivable from the source
(so illustrative values aren't hard-coded). See **Success policies** below.

---

## Architecture

```
  Browser SPA (/dtl/ui)                  File drop (inputs/ + outputs/)
        │  POST /generate, poll /jobs/{id}        │
        ▼                                         ▼
  ┌──────────────────┐  ForgeRequest   ┌─────────────────────┐  ForgeRequest  ┌──────────────────────┐
  │ DTL.REST.Dispatch│ ──(async via──► │ DTL.Svc.            │ ─────────────► │ DTL.Proc.            │
  │ (%CSP.REST)      │   JobManager +  │   PairFileService   │                │   Orchestrator       │
  │  + DTL.Data.Job  │ ◄─Testing.Svc)─ │ (EnsLib.File inbound)│ ◄──────────── │ (regeneration loop)  │
  └──────────────────┘   the BP writes └─────────────────────┘  ForgeResponse └──────────┬───────────┘
        ▲   each attempt into DTL.Data.Job (polled live by the UI)            SendRequestSync│ ▲
        └───────────────────────────────────────────────────────────────────  LLMRequest ▼ │ LLMResponse
                                                                              ┌──────────────────────┐
                                                                              │ DTL.Op.LLMConnector  │
                                                                              │ (EnsLib.HTTP outbound)│
                                                                              └──────────┬───────────┘
                                                                       HTTP /v1/chat/completions
                                                                                         ▼
                                                              OpenAI  ──or──  mock/mock_llm.py (offline)
```

There are **two ways in** — the browser UI / REST API, and the file-drop service —
both feeding the same `DTL.Proc.Orchestrator` regeneration loop.

The Orchestrator calls these **in-process** utilities each attempt (no extra
messaging hops):

| Utility | Role |
|---|---|
| `DTL.Util.PromptBuilder` | System / initial-user / feedback prompts encoding the DTL grammar that compiles. |
| `DTL.Util.Extractor`     | Strips markdown fences and slices out the `Class … }` definition from the LLM reply. |
| `DTL.Util.Verifier`      | Compiles the DTL **from a string** (`$system.OBJ.LoadStream`), runs the transform, normalizes + diffs output vs expected, scores it. |
| `DTL.Util.HL7`           | DocType derivation (structure, not trigger event), line-ending normalization, MSH-offset-correct field access. |

### Components & messages

| Class | Kind |
|---|---|
| `DTL.Svc.PairFileService` | Business **Service** — pairs `inputs/X.hl7` with `outputs/X.hl7`, derives DocTypes, emits a `ForgeRequest`. |
| `DTL.Proc.Orchestrator` | Business **Process** — the generate→compile→run→verify→regenerate loop. |
| `DTL.Op.LLMConnector` | Business **Operation** — OpenAI-compatible chat completions over HTTP (OpenAI **or** mock). |
| `DTL.Msg.ForgeRequest` / `ForgeResponse` | Job in / result out (`Ens.Request` / `Ens.Response`). |
| `DTL.Msg.LLMRequest` / `LLMResponse` | One chat call in / reply out, carrying the accumulating transcript. |
| `DTL.Msg.ChatTurn` / `FieldDiff` / `SamplePair` | `%SerialObject` sub-objects (embedded; no extent pollution). |
| `DTL.REST.Dispatch` | `%CSP.REST` API for the UI (generate / jobs / health / schemas). |
| `DTL.Service.JobManager` | Bridges REST → production: creates a `Job`, dispatches the `ForgeRequest` async. |
| `DTL.Data.Job` / `Attempt` | Persistent job record + per-attempt log (the live progress the UI polls). |
| `DTL.Test.HealthCheck` | Init test hook — verifies every component is initialized (also `GET /health`). |
| `DTL.Setup.Production` | The `Ens.Production` wiring all hosts (OpenAI by default; Mock selectable per job). |
| `DTL.Setup.Installer` | Load + compile + prepare data dirs + wire web apps + start production; `ForgeExample()` helper. |

---

## Quick start (offline, no API key)

Requires Docker.

```bash
scripts/demo.sh
```

This will: start an `intersystemsdc/irishealth-community` container, load and
compile the framework, launch the offline **mock LLM**, start the production,
and run a forge job for each example pair. Expected output:

```
Job ADT_A01_Admit:      success=1 verdict=SUCCESS attempts=3 score=1.000
Job ADT_A08_Update:     success=1 verdict=SUCCESS attempts=3 score=1.000
Job ORU_R01_LabResult:  success=1 verdict=SUCCESS attempts=3 score=1.000
```

The mock LLM scripts a **self-correction curriculum** — it deliberately returns
a *non-compiling* DTL on attempt 1, a *compiling-but-wrong* DTL on attempt 2,
and the *correct* DTL on attempt 3 — so you can watch the loop detect a compile
error, then a field mismatch, then converge.

### Web UI & REST API

The framework ships with a browser UI and a REST API, both served by IRIS.

```bash
IRIS/run.sh                # bring everything up (container, compile, mock, production, web apps)
```

Then open the UI: **http://localhost:52773/dtl/ui/index.html**

- **UI** (`/dtl/ui`): paste an **input specification** (free text) and one or more
  **input/output sample pairs** (add/remove rows); choose the **LLM provider**
  (OpenAI live API, or the offline Mock), the **model** (loaded live from your
  account via the ⟳ button), and enter your **OpenAI API key** (remembered in the
  browser, sent only to your same-origin IRIS server); pick a success policy + max
  attempts; and click **Generate DTL**. A live progress panel shows each attempt
  as it happens (compile-fail → mismatch → success), and a **side-by-side diff
  viewer** shows expected vs the generated DTL's actual output, plus the final
  DTL class source. A health indicator (top-right) runs the init test hook, and a
  links bar deep-links to the **IRIS Production page** and this job's **Visual
  Trace**.
- **REST API** (`/dtl/api`), all JSON:

  | Method & path | Purpose |
  |---|---|
  | `GET /dtl/api/health` | Init/health check (the test hook) — 200 if all green, 503 otherwise. |
  | `GET /dtl/api/schemas` | Installed HL7 schema versions. |
  | `POST /dtl/api/models` | Body `{apiKey}`; server-side proxy to OpenAI `/v1/models` (no browser CORS); returns chat-capable model ids. |
  | `POST /dtl/api/generate` | Start a job; body `{inputSpec, inputName, provider, model, apiKey, maxAttempts, successPolicy, pairs:[{input,output},…]}`; returns `{jobId}`. |
  | `GET /dtl/api/jobs/{id}` | Live job status: attempts log, score, diff, generated DTL, sessionId. |
  | `GET /dtl/api/jobs/{id}/dtl` | The final generated DTL class source (text). |
  | `GET /dtl/api/jobs` | Recent jobs. |
  | `GET /dtl/api/links[/{id}]` | Management-Portal deep links: production config, and (with id) the Visual Trace for that job's session. |

Behind the scenes `POST /generate` creates a persistent `DTL.Data.Job`, dispatches
a `ForgeRequest` **asynchronously** into the running production's orchestrator,
and returns immediately; the orchestrator writes each attempt into the Job record
as it runs, so `GET /jobs/{id}` polling shows live progress. The web apps are
configured for **unauthenticated** access for the demo (default IRIS creds are
`SuperUser` / `SYS`); see `IRIS/README.md` to lock this down.

### File-driven mode

The runtime data directory is **derived from the IRIS manager directory** (no
hardcoded paths) — by default `<mgr>/dtldata/` with `inputs/ outputs/ archive/
results/` beneath it. The installer prints the exact location and wires it into
the production. To find it any time:

```objectscript
write ##class(DTL.Setup.Installer).DataDir()   ; e.g. /usr/irissys/mgr/dtldata/
```

With the production running, drop an input file into that `inputs/` directory:

```bash
DATA=$(docker exec iris-dtl iris session IRIS -U USER \
  "##class(DTL.Setup.Installer).DataDir()")
docker cp inputs/ADT_A01_Admit.hl7 "iris-dtl:${DATA}inputs/"
```

The service pairs it with the matching `outputs/ADT_A01_Admit.hl7`, runs the
loop, archives the input, and writes the generated `.dtl.cls` + `.result.json`
to the `results/` subdirectory.

---

## Example transformations (`inputs/` ↔ `outputs/`)

Same filename = one pair. Each shows a typical health-interface idiom and is
**proven achievable** by a reference DTL (`reference/*.dtl.xml`):

| Pair | Transformation demonstrated |
|---|---|
| `ADT_A01_Admit` | Sending-app rename (`EPICADT`→`EPIC`), facility-code normalization (`SITEA`→`001`) across MSH/PID/PV1, version bump 2.3→2.5. |
| `ADT_A08_Update` | Conditional **code mapping** of administrative sex (`F`→`2`, `M`→`1`, ISO-5218 style) via `<if>`, version bump. |
| `ORU_R01_LabResult` | Header rewrites on a **grouped-segment** structure (PID lives in `PIDgrpgrp(1).PIDgrp`), version bump. |

---

## Success policies (handling the "output may not be a literal transform" caveat)

Set on the `ForgeRequest` / service (`SuccessPolicy`):

| Policy | Accepts when |
|---|---|
| `CompileOnly` | the DTL compiles |
| `CompileRun` | it compiles **and** runs (objective gates only; score reported, not gating) |
| `CompileMatch` *(demo default)* | output is a byte-exact match after normalization |
| `CompileMatchTolerance` | compiles, runs, and `score ≥ MatchThreshold`, ignoring volatile fields (MSH-7 time, MSH-10 control id) |

Normalization always trims the trailing segment terminator that
`OutputToString()` appends and reconciles CR/LF line endings. Field diffs are
classified **HIGH** (expected value is present in the source → derivable) vs
**LOW** (not in the source → likely illustrative; the feedback prompt tells the
LLM *not* to hard-code these). The loop also has **cycle** (identical candidate
repeated) and **plateau** (no score improvement) guards so it never burns the
whole budget on an unsatisfiable pair.

---

## LLM provider — OpenAI (default) or Mock

The framework now defaults to the **real OpenAI API**. The installer creates the
required TLS config (`DTLOpenAISSL`) and the production's `DTL.Op.LLMConnector`
ships with `Mode=openai`, `HTTPServer=api.openai.com:443`. There is nothing to
configure by hand:

1. Open the UI, leave **Provider = OpenAI**, paste your **API key**, click **⟳**
   to load your account's models, pick one, and **Generate**. The key is sent
   per-request to your same-origin IRIS server, used for that job only, and is
   **never** written to the Job record or logs.
2. The offline **Mock** provider is still available — switch the Provider
   dropdown to *Mock* (no key needed) for an offline demo / CI. `IRIS/run.sh`
   starts the mock automatically.

Mock and OpenAI use the **identical wire format** (`POST /v1/chat/completions`);
`DTL.Op.LLMConnector` points the HTTP adapter at the chosen provider per call
(OpenAI over HTTPS+SSL, mock over plaintext) and adds the `Authorization: Bearer`
header when a key is present. You can also set a server-side default key via an
Ensemble credentials entry (`ApiKeyCredentials` setting) instead of per-request.

---

## Security

The framework compiles LLM-authored text in a live namespace, so it treats the
reply as untrusted: `DTL.Util.Verifier.CompileDTL` **extracts only the
`<transform>…</transform>` fragment** and re-wraps it into a forced,
sanitized `DTL.Generated.*` class — it never compiles an LLM-supplied class
wrapper. This neutralizes code-injection via smuggled methods (e.g. a
`[ CodeMode = generator ]` method that would run at compile time) and prevents
generated classes from landing in system packages. `DTL.Test.SecurityTest`
proves both (the injection attempt leaves `^DTLPwned` unset and the `Pwn` method
absent). Throwaway per-attempt classes are deleted; only the winner is promoted.
For a shared IRIS instance or an untrusted endpoint, run the production under a
least-privilege `$ROLES` context.

## Repository layout

```
inputs/        example HL7 v2 input messages
outputs/       example HL7 v2 output messages (same basename = a pair)
reference/     hand-verified reference DTLs proving each pair is achievable
src/DTL/       the framework:
                 Msg/      request/response + sample-pair/chat-turn messages
                 Svc/      file-intake business service
                 Proc/     orchestration business process (the regeneration loop)
                 Op/       LLM business operation (OpenAI/mock over HTTP)
                 Util/     Verifier, HL7, Extractor, PromptBuilder
                 Data/     persistent Job + Attempt records (for the UI/REST)
                 Service/  JobManager (REST→production bridge, async dispatch)
                 REST/     %CSP.REST dispatch class (the API)
                 Setup/    Production + Installer (compile, dirs, web apps)
                 Test/     UtilTest, MockTest, SecurityTest, HealthCheck (init hook)
ui/            the single-file browser SPA (index.html)
mock/          offline OpenAI-compatible mock LLM (mock_llm.py)
scripts/       demo.sh, sync.sh, mock.sh
IRIS/          operator control panel: run.sh, compile.sh, test.sh + README
docs/          DESIGN.md (the synthesized architecture design)
```

See **`IRIS/README.md`** for the run / compile / test control panel.

## Tests

Two terminal-runnable regression suites (also wired into the demo):

```objectscript
do ##class(DTL.Test.UtilTest).RunAll()       ; Verifier/Extractor/HL7 vs the reference DTLs
do ##class(DTL.Test.MockTest).RunAll()       ; the mock's broken→wrong→correct curriculum
do ##class(DTL.Test.SecurityTest).RunAll()   ; code-injection + package-confinement guards
```
