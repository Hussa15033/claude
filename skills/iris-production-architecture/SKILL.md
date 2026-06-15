---
name: iris-production-architecture
description: How to architect a CORRECT InterSystems IRIS Interoperability production — what belongs in a Business Service vs Business Process vs Business Operation, how messages must flow so the Visual Trace shows the real call graph, why long/slow work must run on the durable message queue (never a detached JOB), and the specific anti-patterns that strand work or hide it from the trace. Use when designing or fixing an Ens.Production, deciding how a REST/UI request enters the production, moving work off the HTTP request, debugging a host that "receives but never sends", a job stuck PENDING forever, or a Visual Trace that doesn't show a call. Complements iris-interop-rest (adapter/REST mechanics) with the higher-level component-topology rules.
---

# Architecting a correct IRIS Interoperability production

The rules below are about TOPOLOGY: which component does what, and how messages
move between them. Get this right and every request is durable, supervised, and
fully visible in the Visual Trace. Get it wrong and work silently strands or
disappears from the trace. All proven on IRIS for Health 2026.1.

## The one mental model

A production is a graph of **hosts** that talk ONLY by sending **messages**
(`Ens.Request`/`Ens.Response` subclasses) to each other's config names. There are
exactly three kinds of host, with non-overlapping jobs:

| Host kind | Extends | Its ONE job | Sends to |
|---|---|---|---|
| **Business Service** | `Ens.BusinessService` | The **inbound boundary** — get a message INTO the production (from an adapter feed, or programmatically from REST/installer/tests). | Processes / Operations |
| **Business Process** | `Ens.BusinessProcess` | **Orchestrate** — hold state, make decisions, loop, call out and react. | Operations, other Processes |
| **Business Operation** | `Ens.BusinessOperation` | The **outbound boundary** — talk to one external system (HTTP/LLM, file, SQL, queue). | nothing (leaf) |

If you can't say which of the three a class is, it doesn't belong in the production
as a host — make it a plain `%RegisteredObject` helper that a host CALLS in-process.

## Rule 1 — A message ENTERS the production only through a Business Service

REST handlers, the installer, CLI helpers, tests — anything running OUTSIDE a host —
must submit work by creating YOUR business service and calling a method on it:

```objectscript
set sc=##class(Ens.Director).CreateBusinessService("App.Svc.ApiService",.svc)
set sc=svc.SubmitWork(req)          // your method: SendRequestAsync/Sync to the host
```

Make ONE adapterless service the doorway (driven programmatically, not by a polling
adapter — so no `ADAPTER` parameter; `OnProcessInput` is required but unused). Give
it typed helper methods (`LLM(req,.resp)`, `SubmitConcise(req)`, …) that each send
to the right host. `svc.%SessionId` after a send is the Visual Trace session id.

### ❌ Never use `EnsLib.Testing.Service` as the entry point
It is a TEST HARNESS, not an application component. Using it for real inbound traffic:
- **misuses the class** (it exists to inject test messages by hand), and
- **destroys the trace** — every flow then originates from a single generic
  `EnsLib.Testing.Service` node, so you cannot tell one entry path from another, and
  the production diagram never shows your real boundary.

Symptom that you've made this mistake: the Visual Trace's first hop is
`EnsLib.Testing.Service → …` for unrelated features. Fix: add a real
`App.Svc.ApiService` and route every `CreateBusinessService` through it.

## Rule 2 — Component → component is a DIRECT send from inside the host

Once a message is inside a host, that host sends onward **itself** — never by
spinning up a service to relay. From a Business Process, call:

```objectscript
set sc=..SendRequestSync(..#LLMTARGET, llmReq, .llmResp, 600)   // child of THIS host
```

This is the single most important rule for a readable trace. The call becomes a
**child message of the calling host** in the same session:

```
App.Svc.ApiService → App.Proc.SpecForge      [ConciseRequest]   (entry)
App.Proc.SpecForge → App.Op.LLMConnector      [LLMRequest]       (BP sends directly)
App.Op.LLMConnector → App.Proc.SpecForge      [LLMResponse]
```

### ❌ The "receives but never sends" bug
If a host appears in the trace RECEIVING a message but you never see it SEND the
downstream call, the cause is almost always: a **helper the host called opened its
OWN service session** (e.g. `Ens.Director.CreateBusinessService(...).SendRequestSync`)
instead of the host sending. The downstream call really happened — but in a
SEPARATE session, orphaned from the host. Worse, nesting a fresh service-dispatch
inside a BP actor job ties up that job for the whole call and is a classic way to
make slow calls hang.

**Fix pattern:** a helper that builds the message must NOT send it. Pass the host in
and let the host send:

```objectscript
// helper (plain %RegisteredObject), reused by hosted + non-hosted callers:
ClassMethod CallLLM(pHost As Ens.Host, ...) As %String {
  set req=##class(App.Util.LLM).BuildRequest(...)        // build only
  if $isobject(pHost) {                                  // hosted: host sends → traced child
    set sc=pHost.SendRequestSync(..#LLMTARGET, req, .resp, 600)
  } else {                                               // non-hosted fallback: via the inbound service
    set raw=##class(App.Util.LLM).Chat(...)
  }
}
```
The BP passes `$this`:
`do ##class(App.Service.Foo).Generate($this, token, …)`.

## Rule 3 — Long/slow work runs on the DURABLE QUEUE, never a detached JOB

To move slow work (an LLM call that can take minutes) off the HTTP request, the
correct mechanism is a **persisted message to a Business Process**, dispatched
async:

```objectscript
set svc=##class(Ens.Director).CreateBusinessService("App.Svc.ApiService",.s)
do svc.SubmitWork(req)        // SendRequestAsync to App.Proc.Worker; HTTP returns now
```

Why this is durable and self-healing:
- The request is **persisted** (`Ens.MessageHeader`/queue) before the HTTP call
  returns.
- A pooled worker **always** processes it and writes a terminal status.
- If a worker **dies mid-call**, Ensemble **redelivers** the queued message when the
  production recovers. Nothing is lost.

### ❌ Never use `job MyClass.RunInBackground()` for production work
A detached `JOB` process is UNSUPERVISED and INVISIBLE to the production:
- It does not appear in the Visual Trace at all.
- If it is slow, recycled, or killed (a big Bedrock reply at a 64K output budget is
  enough), it dies before writing a result and the record **strands at PENDING
  forever** — the UI spins indefinitely.
- Any reply it already got is **orphaned**: if your LLM response message carries no
  correlation key (e.g. no token), nothing can re-attach it to the originating
  record. (Do NOT "fix" this with a reaper that flips stranded records to ERROR — it
  can discard a result the model actually produced. Fix the architecture instead.)

Replace the detached job with: a request message + a Business Process host that
carries the correlation id (token/jobId) through the whole lifecycle and always
commits a terminal status. Add the BP to the production with `PoolSize` > 1 so
several can run concurrently.

## Rule 4 — Carry correlation + per-request config ON the message

A stateless operation that serves many jobs needs everything for the call on the
REQUEST, not in operation settings or process-local vars:
- correlation id (token/jobId) so the result lands on the right record even after a
  dehydrate/rehydrate or a redelivery,
- provider/model/region and the **per-user API key** (transient — on the message,
  never persisted to the durable record; it ages out with normal Ens message purge).

State a BP must keep across a `SendRequestSync` (which dehydrates the BP) lives in
**persistent BP properties** (marked `[ Internal ]`), not local variables — locals
do not survive dehydration. (See the regeneration-loop BP for the proven pattern:
`Attempt`, `BestScore`, `Transcript`, … all persistent properties.)

## Rule 5 — Helpers are %RegisteredObject, called in-process

Compute steps that aren't a messaging boundary (compile, diff, parse JSON, build a
prompt, score) should be **plain classmethods** the host calls in-process — NOT extra
hosts and NOT extra messages. Adding a host or a message hop for pure computation
just clutters the trace and adds serialization cost. Reserve messages for crossing a
real boundary (into the production, between orchestration steps, out to a system).

## Concurrency, timeouts, lifecycle
- `PoolSize=1` (default) serializes every message behind one worker — a slow LLM call
  on one job blocks all others. Raise `PoolSize` on the LLM operation AND the
  orchestrating BP, plus production `<ActorPoolSize>`. (Details + the timeout layering
  for slow LLM calls are in the **iris-interop-rest** skill.)
- An adapterless inbound service can run `PoolSize=0` (invoked on demand, no dedicated
  job needed).
- Deleting a host from `Production.cls` or changing `<Setting>`s / PoolSize needs a
  production **stop/start** (not just `UpdateProduction`). Adding an item and most
  setting tweaks apply with `UpdateProduction()`.
- `LoadDir` does NOT remove a class member you deleted from source nor a deleted
  class — purge (`$system.OBJ.Delete("App.*","-d/deleteextent=0")`) then reload when
  you remove a host/method, or runtime hits `<PROPERTY DOES NOT EXIST>` / a ghost item.

## Self-check before shipping a production change
1. Does every inbound path start at a real Business Service (NOT Testing.Service)?
2. Does each host send its downstream calls ITSELF (so the trace shows them as its
   children in one session)?
3. Is every slow/long task on the durable queue (async to a BP), with NO `job`
   command anywhere?
4. Can a worker death only ever RETRY (redelivery) or leave a terminal status — never
   a permanent PENDING?
5. Does each request carry its correlation id + per-call config (key on the message,
   not the record)?
6. Are pure-compute steps in-process helpers, not extra hosts/messages?

If all six are yes, the work is durable, supervised, and fully visible in the Visual
Trace.
