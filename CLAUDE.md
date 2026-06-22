# CLAUDE.md — GenAI → InterSystems DTL framework

Orientation for an LLM session working in this repo (`…/DTL Automation/claude`). Read
this first, then the deeper docs it points to. Keep it updated as the project evolves.

> The repo ROOT also has a `../CLAUDE.md` — that one is the **sandbox/environment**
> guide (shell persistence, networking, git auth, worktrees). This file is the
> **project** guide. Don't confuse them; don't edit the parent one for project facts.

## What this is

An InterSystems **IRIS for Health 2026.1** interoperability application that turns a
written interface **specification** (PDF/DOCX/text — *not* sample messages) into
reviewed, compiled HL7 v2 **DTL** (Data Transformation Language) classes, using an LLM
in a generate→compile→verify→auto-repair loop with human review gates. It is
**project-first** and **spec-driven**.

The goal triad the user cares about, in priority order: **intuitive UI · low cost ·
full transparency.** Weigh changes against those.

## The mental model (how it flows)

```
PROJECT (fixes one HL7 version)
  → attach 1+ SPECIFICATION docs       each: extract → LLM "concise spec" (grouped,
                                       with provenance) → human approves  [gate]
  → SELECT MESSAGE TYPES               derived from approved specs' appliesTo scopes
                                       (pre-ticked) + a family→structure picker to add
                                       ANY other type for the version
  → GENERATE                           one child Job per type, fanned out on the durable
                                       BP queue; each is the single-DTL pipeline seeded
                                       with a per-type spec assembled from the specs
  → REVIEW each DTL                    gate verdict + DTL + synthetic & user test msgs
                                       (schema-validated); accept / reject+feedback /
                                       correct an output  [gate]
  → EXPORT                             one importable XML, or the compiled DTL.Generated.* package
```

No sample messages are required: `DTL.Util.SampleGen` synthesises schema-valid test
inputs; `DTL.Util.SchemaValidate` validates output against the target DocType; the
accuracy gate round-trips them + an LLM-as-judge checks spec conformance. Generated
`<assign>`/`<if>` carry `<annotation>` provenance back to the spec rule.

## Where things live

Source is `src/DTL/` (package `DTL.*`). Key classes:

| Area | Classes |
|---|---|
| **Production hosts** | `Svc.ApiService` (the ONE inbound boundary — adapterless, typed), `Svc.SpecFileService` / `Svc.PairFileService` (file intake), `Proc.SpecForge` (concise-spec on durable queue), `Proc.Orchestrator` (ungated file-drop loop), `Op.LLMConnector` (HTTP → OpenAI / AWS Bedrock / mock, identical wire format) |
| **Orchestration (in-process, REST-driven)** | `Service.StepEngine` (gated build state machine), `Service.ProjectManager` (project lifecycle: create/attach/derive types/assemble per-type spec/fan out/export), `Service.JobManager` (REST→production bridge), `Service.SpecConcise` (concise-spec generate + audit) |
| **Persistent data** | `Data.Project`, `Data.SpecDoc`, `Data.Job` + `Data.Attempt`, `Data.CostEntry` (cost ledger). All carry explicit `Storage` maps so data survives a code purge. |
| **Utilities** | `Util.PromptBuilder`, `Util.LLM` (Chat / BuildRequest[Cached] / ChatReq), `Util.Pricing`, `Util.Cost` (ledger API), `Util.SampleGen`, `Util.SchemaValidate`, `Util.Verifier`, `Util.HL7` / `HL7Schema`, `Util.Extractor` / `DocExtract` / `Py` |
| **REST** | `REST.Dispatch` (`%CSP.REST`, app `/dtl/api`) |
| **Setup / tests** | `Setup.Production`, `Setup.Installer`, `Test.HealthCheck` (init hook + `/dtl/api/health`), `Test.{UtilTest,MockTest,SecurityTest}` |

- `ui/index.html` — the entire front end: a single-file vanilla-JS SPA (~280 KB), served
  same-origin by IRIS at `/dtl/ui/index.html`. No build step.
- `mock/mock_llm.py` — offline OpenAI-compatible LLM (port 8085) for key-free demos/CI.
- `IRIS/` — operator scripts (`run.sh`, `compile.sh`, `test.sh`) + its own README.
- `local_llm_test/` — standalone Python benchmark of the concise-spec step on a local model.

## Build / run / test / deploy

Live dev container is `iris-dtl` (IRIS for Health 2026.1; creds SuperUser / SYS).

- **`IRIS/run.sh`** — canonical deploy: sync source, start mock, **purge `DTL.*` code
  then reload** (clean-slate; `/deleteextent=0` keeps data), start production, copy the
  SPA, print URLs. Use after DELETING a class/member.
- **`IRIS/compile.sh`** — fast incremental compile while editing (does NOT evict deleted members).
- **`IRIS/test.sh`** — HealthCheck (expect `8/8`) + Util/Mock/Security suites.
- UI: `http://localhost:52773/dtl/ui/index.html` · API: `http://localhost:52773/dtl/api/…`
- Quick health: `curl -s localhost:52773/dtl/api/health`.

**Iterating fast against the live container** (without a full `run.sh`):
- ObjectScript: copy `.cls` into the container and `$system.OBJ.Load(file,"ck")`. Use
  FRESH `/tmp/dtlcN_*.cls` names with `chmod 666` (a `docker cp` over a file owned by
  another user fails silently).
- UI: `docker cp ui/index.html iris-dtl:/usr/irissys/mgr/csp/dtlui/index.html` then
  **`docker exec -u root iris-dtl chown irisowner:irisowner … && chmod 644 …`** — skipping
  the chown makes IRIS serve a 404 with NO page error (all JS silently absent).
- After a UI redeploy, Chrome/Playwright HTTP-cache the page by URL — a stale screenshot
  can show the OLD UI while `curl … | grep <marker>` shows the new. Bust with `?cb=<ts>`.

## Conventions that matter (read before changing things)

- **Cost ledger is the single source of truth.** Every LLM call → one `Data.CostEntry`
  row via `Util.Cost.Record(category, refKind, refId, label, model, inTok, outTok)`;
  the dollar amount is computed there from tokens (one `Util.Pricing` table) and the
  account grand total `^DTL.Usage` is bumped there. Categories: `spec.generate`,
  `spec.verify`, `dtl.plan`, `dtl.generate`, `dtl.judge`. Per-spec / per-DTL / project /
  grand totals are all SUMS of ledger rows — never keep a second tally. `Job.UsageSummary`
  reads the ledger (`Cost.ForRef(jobId)`), NOT the transcript. If you add an LLM call,
  record it, or the numbers stop reconciling.
- **Prompt-cache the big static prefix.** Build path caches its system prompt (DTL+HL7
  schema + structured spec); spec path caches the raw source document across
  generate/audit/retry/regeneration. Cache hits need the prefix BYTE-identical — keep the
  document in a shared system block flagged `CacheBreakpoint`, not inside per-call prompts.
- **Production architecture rules (firm).** Work enters ONLY via a real Business Service
  (`Svc.ApiService`), never `EnsLib.Testing.Service`. Component→component is a direct host
  send (so the Visual Trace shows the real call graph). Slow/long work runs on the durable
  message queue, never a detached `JOB`. Per-request API keys ride on the message, used for
  that job only, NEVER written to a record or log.
- **DANGER:** do NOT `iris stop`/`iris start` mid-operation (it has destroyed the USER DB).
  Prefer `docker restart iris-dtl`.
- **`iris session` heredoc:** one statement per line; multi-line `{ }` blocks and `$$$macros`
  fail there. For loops/macros, write a `.cls`/`.mac` and Load it.
- Generated classes are confined to the `DTL.Generated.*` package; the engine never compiles
  an LLM-supplied class wrapper (injection guard — see `Test.SecurityTest`).

## Authoritative references

- **`README.md`** — the full as-built architecture, the spec-driven flow, the success/
  accuracy policy, security, the complete REST table, repository layout. Start here for depth.
- **`IRIS/README.md`** — operator's guide (compile/run/test, clean-slate-recompile rationale,
  where data lives in the container, provider setup).
- **`skills/`** — portable, gotcha-rich SKILL files (Claude Agent Skills format). Most relevant:
  `dtl-generation` (DTL + the LLM loop + cost ledger + caching), `intersystems-ui-theme`
  (the SPA patterns + review-gate/spinner + Playwright cache trap),
  `iris-production-architecture`, `iris-interop-rest`, `objectscript-gotchas`,
  `iris-embedded-python`, `iris-docker-ops`. `skills/README.md` indexes them.
- **`docs/DESIGN.md`** — HISTORICAL v1 (pair-driven) design, kept for rationale; its top
  preamble flags that the README supersedes it. Don't treat its body as current.

## Status

Project-first + spec-driven, verified end-to-end live (mock, AWS Bedrock/Anthropic, OpenAI).
Roadmap (see README): reusable `<subtransform>` factoring; message-flow trace mapping a
message back to the spec rules that fired (via the `<annotation>` provenance).
