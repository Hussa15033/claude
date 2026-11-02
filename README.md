# DTL Auto-Generation Framework (GenAI → InterSystems DTL)

A framework that **uses GenAI to write InterSystems IRIS Data Transformation
Language (DTL)** for HL7 v2 interface mappings — driven by a **written
specification**, not by sample messages.

## The problem this solves

When an implementation partner builds an HL7 v2 interface, they almost always
work from a **specification document** and rarely have more than a handful of
sample messages — sometimes none. The traditional workflow is painful:

> hand-write a DTL in IRIS → test it against whatever sample messages you can
> scrape together → manually read the HL7 schema to check the output is valid →
> repeat.

This framework collapses that loop. You give it the **spec** (and, optionally,
the message types you care about); it asks an LLM to author the DTL, then —
because you usually have no samples — it **manufactures schema-valid test
messages itself**, runs the DTL, **validates the output against the target HL7
schema automatically**, judges it against the spec, and regenerates on failure.
A human reviews a spec that has been distilled to an explicit rule list, then
reviews the finished DTL, with the produced output already schema-checked.

> Verified running in a live **IRIS for Health 2026.1** container, end to end,
> against a built-in offline mock LLM (no API key required), and against AWS
> Bedrock (Anthropic Claude) and OpenAI.

---

## Projects — building a whole interface at once

The top-level unit of work is a **project**. A project fixes the **HL7 version** for all
its transformations, holds **one or more specification documents**, and generates a
reviewed DTL for **every message type you select**.

```
 CREATE PROJECT           name + HL7 version (fixed for the whole project)
        │
 ADD SPECIFICATIONS       attach one or more spec docs; each is reviewed independently
        │                 (concise spec + your approval — the per-document gate below)
        ▼
 SELECT MESSAGE TYPES     once every spec is approved, the project DERIVES the HL7
        │                 message types the specs cover (from each rule's appliesTo
        │                 scope) and pre-selects them. A family→structure picker also
        │                 lets you add ANY other message type for the version. Tick the
        │                 ones to build. (Specs lock here — "the real work has started".)
        ▼
 GENERATE ALL             one child job per selected type, fanned out concurrently on
        │                 the durable BP queue. Each is the proven single-DTL pipeline,
        │                 seeded with a per-type spec ASSEMBLED from the approved specs
        │                 (wildcard/shared rules + rules scoped to that type).
        ▼
 REVIEW EACH DTL          open any transformation → review the gate verdict, the DTL,
        │                 the synthetic + your test messages and their schema validity;
        │                 send live messages through it; converse with the AI to change
        │                 it (reject + feedback / correct an output) until happy.
        ▼
 SAVE / EXPORT            the generated DTLs are compiled classes in the IRIS namespace
                          (the "package"); export them all as one importable XML.
```

Per-type spec assembly is the crux: a project spec covers many message types, but a
DTL targets one. For each selected type the project gathers every approved rule whose
`appliesTo` is `*` (generic/shared) **or** names that type, and builds a focused spec —
so each child job's plan/generate/judge see only what's in scope. Reusable
`<subtransform>` factoring of shared rules is on the **roadmap** (below).

## Cost transparency — one ledger, everything reconciles

Every LLM call the system makes — spec generation, spec audit, and each DTL's plan /
generate / judge — writes one row to a **cost ledger** (`DTL.Data.CostEntry`), with the
dollar amount computed at record time from the reported tokens via a single pricing
table (`DTL.Util.Pricing`). **Every figure shown anywhere is a sum of ledger rows**, so
they can't disagree:

- **Per specification** — generation + audit cost, shown on each spec row.
- **Per DTL (message type)** — plan + generate + judge cost.
- **Project total** = its specs' + DTLs' rows; **account grand total** = a running
  counter the same recorder maintains.
- A **Costs & ledger** tab on each project shows the breakdown plus the full
  chronological ledger (every call, labelled, filterable by category), and the project
  list + a stats strip surface the headline cost/score/token figures. Costs tick live
  while DTLs build.

Cost is kept low by **prompt-caching the large static prefixes**: the build path caches
its system prompt (DTL + HL7 schema + structured spec), and the spec path caches the raw
source document across its generate + audit + retries + regenerations — billed once,
re-read from cache (~10% of input price) thereafter (Anthropic/Bedrock `cache_control`;
OpenAI automatic prefix caching). See `GET /projects/:tok/costs`.

## How a single transformation is built (the spec-driven, human-gated flow)

Each message type in a project runs this pipeline (it is also the engine behind the
whole framework):

```
 1. UPLOAD / TYPE SPEC          PDF · DOCX · text  →  extracted to markdown
        │
 2. CONCISE SPEC (LLM)          de-noised, grouped by message/segment type, every
        │                       rule carries a verbatim source quote + appliesTo scope
        ▼
 3. REVIEW SPEC (human gate)    side-by-side: original ⇄ rule list; move rules between
        │                       groups, resolve ambiguities (each shows its source passage)
        ▼
 4. PLAN (LLM)                  one line per in-scope rule; coverage + conditional-rule gates
        │                       ensure nothing is silently dropped
        ▼  (human approves)
 5. GENERATE DTL (LLM)          from the SPEC only — the message is never required.
        │                       Each <assign>/<if> annotated with the spec rule it implements.
        ▼
 6. ACCURACY GATE (automatic)   ┌ run on synthetic + any user messages
        │                       ├ schema-validate every OUTPUT vs the target DocType
        │                       └ LLM-as-judge conformance vs the spec
        ▼  (auto-repair loop on failure: compile / runtime / schema / spec findings fed back)
 7. REVIEW DTL (human gate)     informed review: gate verdict, per-message output validity,
        │                       diff, full DTL source. Accept, reject+feedback, or correct.
        ▼
 8. USE                         transform live messages, refine via conversation, export.
```

Steps 2–3 are the **earliest, cheapest checkpoint**: an extraction or
interpretation error is caught on a one-page rule list *before* any DTL is built.
The approved spec then becomes the single **authority** every later step is
grounded on.

### What makes it spec-driven, not sample-driven

| Capability | Class | What it does |
|---|---|---|
| **Synthetic input generation** | `DTL.Util.SampleGen` | Walks the IRIS HL7 schema and manufactures **structurally-valid** synthetic input messages for any DocType — `minimal` (required segments only), `full` (+ optionals), `seeded` (spec-derived values woven in so conditional rules fire). Datatype-aware and deterministic. No real samples needed. |
| **Output schema validation** | `DTL.Util.SchemaValidate` | Runs IRIS's own validator (`Validate("dm")`) on the **produced** message against the target DocType and decomposes the result into structured findings `{kind, segment, field, severity, message}`. Automates the manual "check the output against the schema" step. |
| **Round-trip accuracy gate** | `DTL.Service.StepEngine` | Generates synthetic inputs → runs the DTL over them *and* any user-supplied samples → schema-validates every output → feeds structural defects back into the repair loop. A schema-invalid output **hard-blocks** success. |
| **Per-rule provenance** | `DTL.Util.PromptBuilder` | Generated DTL attaches an `<annotation>` child to each `<assign>`/`<if>` naming the spec rule it implements, so every field change is traceable back to the requirement — inside the class itself. |

You can still **bring your own sample messages** (optional): they are run and
schema-validated alongside the synthetic set, and a supplied message also
identifies the message type if you don't pick one explicitly.

---

## Architecture

The framework is an **IRIS Interoperability production**. Everything enters
through a real Business Service and flows through the production so every message
is visible in the **Visual Trace** (no detached jobs, no test harnesses used as
entry points).

```
  Browser SPA (/dtl/ui)                         File drop (inputs/)
        │  REST: upload, concise, generate, jobs        │
        ▼                                               ▼
  ┌──────────────────┐                          ┌──────────────────────┐
  │ DTL.REST.Dispatch│   typed methods          │ DTL.Svc.SpecFileService│  (spec docs)
  │ (%CSP.REST)      │ ───────────────►┐        │ DTL.Svc.PairFileService│  (sample pairs)
  └──────────────────┘                 ▼        └───────────┬──────────┘
                              ┌──────────────────────┐      │
                              │ DTL.Svc.ApiService    │◄─────┘   the single inbound
                              │ (Business Service,    │          boundary — typed
                              │  adapterless)         │          methods, fully traced
                              └───────┬───────────────┘
                  SubmitConcise │     │ Submit/Forge │ LLM (sync)
                   (async)      ▼     ▼              ▼
              ┌────────────────────┐ ┌──────────────────────┐
              │ DTL.Proc.SpecForge │ │ DTL.Proc.Orchestrator │   durable BP queues
              │ (concise spec gen) │ │ (regeneration loop)   │   (PoolSize > 1)
              └─────────┬──────────┘ └──────────┬───────────┘
                        │  SendRequestSync (host sends directly → child in trace)
                        ▼                        ▼
                              ┌──────────────────────┐
                              │ DTL.Op.LLMConnector   │  Business Operation
                              │ (HTTP: OpenAI /       │  /v1/chat/completions
                              │  Bedrock / Mock)      │
                              └──────────┬───────────┘
                                         ▼
                    OpenAI · AWS Bedrock (Anthropic) · mock/mock_llm.py (offline)
```

The gated, step-by-step build (the UI's default) is driven **synchronously per
step** by `DTL.Service.StepEngine`, persisting all state on `DTL.Data.Job` so each
REST `/continue` call advances exactly one step and the conversation survives
across user think-time. The ungated auto-run path (`DTL.Proc.Orchestrator`) drives
the whole loop in one shot for the file-drop / test flows.

### In-process utilities (no extra messaging hops)

| Utility | Role |
|---|---|
| `DTL.Util.PromptBuilder` | All prompts: spec-structuring, concise spec, plan (+ coverage/conditional gates), generate, repair, judge — encoding the DTL grammar that compiles and the HL7 schema for the DocType. |
| `DTL.Util.Extractor` | Strips markdown fences and slices the `Class … }` definition out of the LLM reply. |
| `DTL.Util.Verifier` | Compiles the DTL **from a string** (`$system.OBJ.LoadStream`), runs the transform, diffs/scores output, reports changed fields. Security boundary: compiles only the `<transform>` fragment. |
| `DTL.Util.SampleGen` | Schema-driven synthetic HL7 input generator (see above). |
| `DTL.Util.SchemaValidate` | Output-vs-target-schema validator (see above). |
| `DTL.Util.HL7` / `DTL.Util.HL7Schema` | DocType derivation, MSH-offset-correct field access; renders the exact valid segment paths/fields for a DocType into the prompt. |

### Components & messages

| Class | Kind |
|---|---|
| `DTL.Svc.ApiService` | Business **Service** — the single, adapterless inbound boundary; typed methods (`LLM`, `SubmitConcise`, `SubmitForge`, `Forge`) so every call is traced. |
| `DTL.Svc.SpecFileService` / `PairFileService` | Business **Services** — file-drop intake for spec documents and sample pairs. |
| `DTL.Proc.SpecForge` | Business **Process** — durable-queue worker that generates + verifies the concise spec. |
| `DTL.Proc.Orchestrator` | Business **Process** — the ungated generate→compile→run→verify→regenerate loop. |
| `DTL.Op.LLMConnector` | Business **Operation** — OpenAI-compatible chat completions over HTTP (OpenAI, AWS Bedrock, or mock), with prompt caching. |
| `DTL.Service.StepEngine` | The **gated** state machine: structure → plan → generate → accuracy-gate → review, all on `DTL.Data.Job`. |
| `DTL.Service.ProjectManager` | Project lifecycle: create, attach specs, derive message types (parse `appliesTo`), assemble per-type specs, fan out child jobs, roll up status, export XML. |
| `DTL.Data.Project` | Persistent project record: HL7 version, attached spec tokens, selected types, child job ids, lifecycle status. |
| `DTL.Service.JobManager` | Bridges REST → production: creates a `Job`, dispatches into the production. |
| `DTL.Data.Job` / `Attempt` | Persistent job record + per-attempt log (the live progress the UI polls). |
| `DTL.Data.SpecDoc` | Persistent uploaded-spec record: extracted text, concise spec, provenance, approval state. |
| `DTL.Msg.*` | `ConciseRequest`, `ForgeRequest`/`Response`, `LLMRequest`/`Response`, `ChatTurn`, `SamplePair`. |
| `DTL.REST.Dispatch` | `%CSP.REST` API for the UI. |
| `DTL.Setup.Production` / `Installer` | Production wiring; load + compile + data dirs + web apps + start. |
| `DTL.Test.HealthCheck` / `MockTest` / `UtilTest` / `SecurityTest` | Init hook + regression suites. |

---

## Quick start (offline, no API key)

Requires Docker.

```bash
IRIS/run.sh                # container, clean compile, mock LLM, production, web apps
```

Then open **http://localhost:52773/dtl/ui/index.html**.

`IRIS/run.sh` does a **clean-slate recompile** (purges the `DTL.*` code, keeping
persistent data, then reloads) so a deleted class member can never linger as
stale compiled code. Use `IRIS/compile.sh` for a fast incremental edit loop.

### Using the UI

1. **Provide a specification** — type one or upload a document (PDF/DOCX/…); the
   Specification Builder extracts it, the LLM produces a **concise, grouped,
   source-referenced** spec, and you **review & approve** it (the earliest gate).
2. **Choose the message type** to build the transformation for (loaded from the
   installed HL7 schemas). No sample message is required — optionally expand
   *"test with your own sample messages"* to add real ones.
3. **Plan & Generate** — watch each step (structure → plan → generate →
   auto-repair) live. The **accuracy gate** shows: runs on all messages, output
   valid vs the HL7 schema (N/N), and the spec-conformance judge score.
4. **Review** — accept, reject with feedback (regenerates), or correct an output
   directly. The **Outputs** tab shows every test message (synthetic + yours)
   with its schema-validity badge.

### LLM provider — OpenAI · AWS Bedrock · Mock

Mock and the live providers use the **identical wire format**
(`POST /v1/chat/completions`). Pick the provider in Settings; the API key is sent
per-request to your same-origin IRIS server, used for that job only, and is
**never** written to the Job record or logs. `IRIS/run.sh` starts the offline
mock automatically for key-free demos/CI.

---

## REST API (`/dtl/api`, all JSON)

| Method & path | Purpose |
|---|---|
| `GET /health` | Init/health check (the test hook) — 200 if all green. |
| `GET /projects` · `POST /projects` | List projects / create one (`{name, hl7Version, provider, model, …}`). |
| `GET /projects/:tok` | Full project document: specs (+ review status), selected types, per-job summary. |
| `POST /projects/:tok/specs` · `DELETE …/specs/:spec` | Attach / detach a spec (DRAFT only). |
| `GET /projects/:tok/types` | Message types derived from the approved specs (pre-selected) **plus** the full catalogue of every structure for the version, grouped by family, for the picker. |
| `POST /projects/:tok/generate` | Lock specs + fan out one child job per selected type (`{types:[…], apiKey, region}`). |
| `GET /projects/:tok/costs` | Full cost breakdown from the ledger: per-spec, per-DTL, the labelled chronological timeline, project total, account grand total. |
| `GET /projects/:tok/package` · `GET …/export` | List the project's generated DTL classes / download them all as one importable XML. |
| `GET /schemas` | Installed HL7 schema versions **and** the full `version:structure` DocType list (for the message-type picker). |
| `POST /models` · `POST /bedrock-models` | Server-side proxy to list chat-capable models for OpenAI / Bedrock. |
| `POST /upload` | Upload a spec document; returns a `{token}` the UI polls. |
| `GET /specs` · `GET /specs/:token` | List approved specs / fetch one (text, concise spec, provenance, status). |
| `POST /specs/:token/concise` · `/verify-concise` · `/skip-verify` · `/approve-concise` | Generate / audit / skip-audit / approve the concise spec. |
| `POST /generate` | Start a job; body `{inputSpec\|specToken, sourceDocType, targetDocType, inputs[], provider, model, apiKey, maxAttempts, costCap}`; returns `{jobId}`. |
| `GET /jobs/:id` | Live job status: attempts, gate report, diff, generated DTL, sessionId. |
| `GET /jobs/:id/dtl` | The final generated DTL class source (text). |
| `POST /jobs/:id/continue` | Advance a gated job: `approve-spec` / `approve` / `accept` / `reject`. |
| `GET /jobs/:id/outputs` | Every test message (user + synthetic) transformed, each with its output-vs-schema validation verdict. |
| `GET /jobs/:id/synthetic` | The synthetic, spec-derived input messages generated to test this DTL. |
| `POST /jobs/:id/transform` · `/correct` · `/refine` | Run the DTL on an ad-hoc message · apply a correction · spawn a refinement job. |
| `GET /jobs/:id/messages` | The full LLM conversation (every request/response) for transparency. |
| `GET /classes` · `GET /history` · `GET /links[/:id]` | Generated classes · job lineage · Management-Portal / Visual-Trace deep links. |

---

## Success / accuracy policy

Spec-driven jobs gate on **spec conformance**, not a byte match (there is no
expected output to match against). The accuracy gate passes only when the DTL:

1. **runs** cleanly on every test message (synthetic + user), and
2. produces output that is **valid against the target HL7 schema** (no HIGH
   structural defect — missing required segment, bad datatype, …), and
3. has **no HIGH-severity spec-conformance violation** from the LLM judge.

LOW-severity findings and the advisory "no field changed" coverage signal inform
the reviewer but don't block success. The repair loop has **cycle** (identical
candidate) and **plateau** (no score improvement) guards plus a per-job **cost
cap**, so it never burns the whole budget on an unsatisfiable spec.

(The legacy pair-driven policies — `CompileOnly` / `CompileRun` / `CompileMatch`
/ `CompileMatchTolerance` — still exist for the file-drop flow that *does* have an
expected output.)

---

## Security

The framework compiles LLM-authored text in a live namespace, so it treats the
reply as untrusted: `DTL.Util.Verifier.CompileDTL` **extracts only the
`<transform>…</transform>` fragment** and re-wraps it into a forced, sanitized
`DTL.Generated.*` class — it never compiles an LLM-supplied class wrapper. This
neutralizes code injection via smuggled methods (e.g. a `[ CodeMode = generator ]`
member that would run at compile time) and confines generated classes to one
package. `DTL.Test.SecurityTest` proves both. Throwaway per-attempt classes are
deleted; only the winner is promoted. For a shared instance, run the production
under a least-privilege `$ROLES` context.

## Roadmap

Planned, not yet built:

- **Reusable sub-transformations (`<subtransform>`).** Factor a segment-level rule
  shared across many message types (e.g. a common PID normalization) into a
  standalone sub-DTL and call it via `<subtransform>` from each parent. Deferred
  deliberately: a sub-DTL runs on a sub-document/segment, which the current
  whole-message `DTL.Util.SampleGen` / `DTL.Util.SchemaValidate` cannot generate or
  validate in isolation — so per-sub-transform verification (and "send a live
  message to each subtransformation") needs sub-document-level test generation and
  validation designed in first. Until then, each message type produces one
  self-contained DTL and shared logic is duplicated rather than factored out.
- **Message-flow trace** — show which project DTL a given message routes to (via an
  HL7 routing production / Visual Trace) and, using the per-rule `<annotation>`
  provenance, which spec rules fired for that message (diff input↔output, map each
  changed field back to its annotated rule).

## Repository layout

```
inputs/        example HL7 v2 input messages (file-drop demo)
outputs/       example HL7 v2 output messages (same basename = a pair)
reference/     hand-verified reference DTLs proving each pair is achievable
src/DTL/       the framework:
                 Msg/      request/response + chat-turn/sample-pair messages
                 Svc/      ApiService (inbound boundary) + file-intake services
                 Proc/     SpecForge + Orchestrator business processes
                 Op/       LLM business operation (OpenAI/Bedrock/mock over HTTP)
                 Util/     Verifier, SampleGen, SchemaValidate, HL7, HL7Schema,
                           Extractor, PromptBuilder, Pricing, Cost (ledger API), …
                 Data/     persistent Job/Attempt + SpecDoc + Project + CostEntry records
                 Service/  StepEngine (gated state machine), JobManager (REST bridge),
                           ProjectManager (project orchestration),
                           SpecConcise (concise-spec generation)
                 REST/     %CSP.REST dispatch class (the API)
                 Setup/    Production + Installer
                 Test/     HealthCheck (init hook), MockTest, UtilTest, SecurityTest
ui/            the single-file browser SPA (index.html)
mock/          offline OpenAI-compatible mock LLM (mock_llm.py)
scripts/       sync.sh, mock.sh
skills/        IRIS production-architecture + interop-REST authoring skills
IRIS/          operator control panel: run.sh, compile.sh, test.sh + README
docs/          DESIGN.md
```

## Tests

```objectscript
do ##class(DTL.Test.UtilTest).RunAll()       ; Verifier/Extractor/HL7 vs the reference DTLs
do ##class(DTL.Test.MockTest).RunAll()       ; the mock's broken→wrong→correct curriculum
do ##class(DTL.Test.SecurityTest).RunAll()   ; code-injection + package-confinement guards
```

`GET /dtl/api/health` runs the init hook (`DTL.Test.HealthCheck`) and returns 200
only when every production component is initialized.
