---
name: iris-interop-rest
description: Building IRIS Interoperability productions and %CSP.REST APIs — business services/processes/operations, the HTTP outbound adapter (incl. parsing provider HTTP errors descriptively), FileInboundAdapter, creating CSP web apps programmatically, async dispatch into a running production, unauthenticated access, and Visual Trace deep-links. Use when wiring an Ens.Production, exposing REST endpoints, calling an external HTTP/LLM API from IRIS, ingesting/listing files, or driving a job from a UI.
---

# IRIS Interoperability + REST

Patterns and traps for building an interoperability production fronted by a REST
API. All verified on IRIS for Health 2026.1.

## EnsLib.HTTP.OutboundAdapter — sending a raw JSON body

To POST a JSON body (not form variables) through the hosted adapter:

```objectscript
set req=##class(%Net.HttpRequest).%New()  set req.ContentType="application/json"
do req.SetHeader("Authorization","Bearer "_key)        // optional
kill data  set data(1)=jsonString                       // SUBSCRIPTED array node!
set sc=..Adapter.SendFormDataArray(.resp,"Post",req,"",.data,"/v1/chat/completions")
```

- `pData` MUST be a **subscripted array** (`data(1)=...`); a plain string sends an
  EMPTY body. The adapter iterates `pData` via `$ORDER` and writes each node to the
  EntityBody.
- Do NOT use `..Adapter.Post(.resp,path,req)` — its 2nd arg is form-var NAMES, so
  it form-encodes your path and sends `x-www-form-urlencoded` garbage.
- Switch provider/target at call time: `set ..Adapter.HTTPServer=host, ..Adapter.HTTPPort=port, ..Adapter.SSLConfig=cfg` (all runtime-settable).
- OpenAI over HTTPS needs an SSL config; the community image ships with **none** —
  create one: `##class(Security.SSLConfigs).Create("MySSL")` (in %SYS). `api.openai.com:443` is reachable.

### One hosted adapter, many LLM providers (OpenAI + AWS Bedrock + mock)

One `EnsLib.HTTP.OutboundAdapter` operation can serve several providers — switch
`HTTPServer`/`HTTPPort`/`SSLConfig` and the body/path per request:

- **OpenAI / mock** — `POST /v1/chat/completions`, body `{model, messages:[{role,content}], max_tokens}`, response `choices[0].message.content`. Auth: `Authorization: Bearer <key>`.
  **Newer OpenAI models reject `max_tokens` AND `temperature`.** gpt-5*/o-series
  (o1/o3/o4) reasoning models 400 with "Unsupported parameter: 'max_tokens' is not
  supported with this model. Use 'max_completion_tokens' instead." — and only accept
  the default temperature. Detect them by model-id prefix (`gpt-5`/`gpt-6`/`o1`/`o3`/
  `o4`) and switch the body: emit `max_completion_tokens` instead of `max_tokens` and
  OMIT `temperature` entirely. Legacy models (gpt-4o, gpt-4-turbo, gpt-3.5) keep
  `max_tokens`+`temperature`. Bedrock is unaffected (it uses its own `max_tokens`).
- **AWS Bedrock (Claude)** — host `bedrock-runtime.<region>.amazonaws.com`, path
  `POST /model/<url-encoded-model-id>/invoke`, **Anthropic Messages** body
  (`{anthropic_version:"bedrock-2023-05-31", max_tokens, system:"…", messages:[…]}`
  — system is a TOP-LEVEL string, NOT a message), response is a content-block array
  → concatenate the `type=="text"` blocks; usage is `input_tokens+output_tokens`.
  Auth: a **Bedrock long-lived API key** as `Authorization: Bearer <key>` (no SigV4
  needed — set one with `aws bedrock create-api-key` or in the console). URL-encode
  the model id — inference-profile ids contain colons (`us.anthropic.claude-opus-4-8-v1:0`).
  Allow `bedrock-runtime.<region>.amazonaws.com` in the network policy; reuse the
  same `SSLConfig` as OpenAI. A bad key returns a clean Bedrock 403
  (`{"Message":"Invalid API Key format…"}`) through the descriptive-error path below.

Thread per-request provider config (provider, model, key, region) on the request
message, not just operation settings, so one running operation serves every job.

**Bedrock model ids — list, don't guess.** A bare foundation-model id
(`anthropic.claude-opus-4-7`) returns 400 "on-demand throughput isn't supported";
you must invoke a **regional inference-profile id**. But those ids carry account-
and region-specific suffixes, so hardcoded guesses also 400 ("provided model
identifier is invalid"). List them from the **control plane** (a different host
from runtime): `GET https://bedrock.<region>.amazonaws.com/inference-profiles`
(and `/foundation-models?byProvider=anthropic&byInferenceType=ON_DEMAND`) with the
same `Authorization: Bearer <key>`. Surface those exact ids in the UI and let the
user paste one — never ship a hardcoded profile id as a working default.

**Token usage + cost.** Both providers report usage: OpenAI `usage.{prompt_tokens,
completion_tokens,total_tokens}`, Bedrock `usage.{input_tokens,output_tokens}`.
Capture the in/out split (not just a total) on the response, attach it to the
record that produced it, and cost it from a per-model price table (USD/1M tokens,
substring-keyed, unknown→0 rather than guessing) so you can show per-request and
running totals.

### Timeouts for a slow LLM operation (don't fail a slow completion)
The defaults are far too short for an LLM call. An `Ens.BusinessOperation` retries
until its **`FailureTimeout`** (Host setting, default **15s**) elapses, and the
`EnsLib.HTTP.OutboundAdapter` waits **`ResponseTimeout`** (default **30s**) for one
HTTP read — both well under the minutes a reasoning model (gpt-5.x, o-series) can
take, so the request fails mid-flight. Raise all THREE layers that bound the call:
`FailureTimeout` (e.g. 600) on the operation, `ResponseTimeout` (e.g. 300) on the
adapter, AND the BP→operation `SendRequestSync(...,timeout)` wait (e.g. 600) — the
sync wait must exceed the operation's own budget or the BP gives up first. Set the
first two as production `<Setting>`s; a Production.cls settings change needs a
stop/start (not just UpdateProduction) to take effect.

### Surface HTTP errors descriptively (a 400 is not a transport failure)

A non-2xx response (bad model, bad key, rate limit) comes back through
`SendFormDataArray` as an **error %Status** (`<Ens>ErrHTTPStatus: non-OK status
400`) — but the populated `pResp` object usually still carries the provider's error
**body**. Don't surface the raw transport text; in the `$$$ISERR` branch read the
body off the response and parse the provider's JSON:

```objectscript
set tCode=$select($isobject($get(tResp)):+tResp.StatusCode,1:0)
set tBody="" try { set tBody=tResp.Data.Read(3600000) } catch {}
// OpenAI: {"error":{"message","type","code"}} -> build an actionable message,
// keyed by STATUS code first (401 auth, 403 access, 404 model/path, 429 rate/quota,
// 5xx transient), THEN the model case (code="model_not_found").
```

Branch on the **HTTP status, not `error.type`** — OpenAI tags a bad-model 400 AND a
401 both as `invalid_request_error`, so keying off the type mislabels auth failures.
A genuine transport error (DNS/TLS/refused) has `tCode=0`; describe that separately
(SSL/host/firewall hints).

## %CSP.REST dispatch class

```objectscript
Class X.REST.Dispatch Extends %CSP.REST {
Parameter HandleCorsRequest = 1;
XData UrlMap { <Routes>
  <Route Url="/health" Method="GET" Call="Health" Cors="true"/>
  <Route Url="/jobs/:id" Method="GET" Call="GetJob" Cors="true"/>
</Routes> }
ClassMethod GetJob(pId) As %Status { ... do ..Json(obj) quit $$$OK }
}
```

- Parse the body: `set obj={}.%FromJSON(%request.Content)`.
- Build the host URL for portal links from CGI vars **inside a try** (a missing
  var can 500 the endpoint): `%request.GetCgiEnv("SERVER_NAME","")` / `"SERVER_PORT"`.
- **Do not name a handler `Error`** — it clashes with a `%CSP.REST` method
  (`#5478 keyword signature error`). Use `ErrJson` etc.
- Same `quit`-in-`try` rule as all ObjectScript: use `return` (see objectscript-gotchas).

## Creating CSP web apps programmatically (must be done in %SYS)

```objectscript
new $namespace  set $namespace="%SYS"
kill p set p("NameSpace")="USER", p("DispatchClass")="X.REST.Dispatch"
set p("AutheEnabled")=64, p("Enabled")=1, p("CookiePath")="/x/api/"
do ##class(Security.Applications).Create("/x/api",.p)      // or .Modify if exists
// static UI app:
kill q set q("NameSpace")="USER", q("Path")=physicalDir, q("AutheEnabled")=64
set q("Enabled")=1, q("ServeFiles")=2, q("CSPZENEnabled")=1
do ##class(Security.Applications).Create("/x/ui",.q)
```

**CRITICAL cross-namespace trap:** `Security.Applications`/`Security.Users` are
visible ONLY in `%SYS`; your app classes (`X.*`) are visible ONLY in `USER`. So a
method that does `set $namespace="%SYS"` must NOT then call a sibling `X.*` method
(`<CLASS DOES NOT EXIST>`). Do all `Security.*` work **inline** in one method
bracketed by the namespace switch; don't delegate to your own classes while in %SYS.

### AutheEnabled bit meaning (cost a long debug)

`64` = **unauthenticated**; `32` = password; `96` = both. For a no-login demo set
`64` AND grant the `UnknownUser` the needed roles (demo only):
`do ##class(Security.Users).Get("UnknownUser",.u)` then add `%All` to `u("Roles")`
and `Modify`. `ServeFiles=2` (not 1) for static-file apps. `Create` sometimes
ignores `AutheEnabled` — follow with a `Modify` to enforce it.

## Async dispatch into a running production (UI → BP)

To kick a business process from REST and return immediately, use the built-in
testing service (add `EnsLib.Testing.Service` as a production item):

```objectscript
set sc=##class(Ens.Director).CreateBusinessService("EnsLib.Testing.Service",.svc)
set sc=svc.SendRequestAsync("X.Proc.MyBP",req)     // or SendRequestSync(...,.resp,timeout)
```
`svc.%SessionId` after a send gives the interop session id for a Visual Trace link.
Outside a STARTED production this fails with `ErrBusinessDispatchNameNotRegistered`.

## FileInboundAdapter — the boot-with-path rule

A business service `Extends Ens.BusinessService` with
`Parameter ADAPTER="EnsLib.File.InboundAdapter"` and
`OnProcessInput(pInput,Output pOutput,ByRef pHint)`:

- Get the file path from **`pInput.Filename`** (the adapter passes a
  `%Library.FileCharacterStream`); `pHint` is not reliably populated.
- If the REST upload pre-created a record with the ORIGINAL filename, do NOT
  overwrite it in `OnProcessInput` — the adapter only knows the on-disk
  `<token>.ext` name, so a blind `set rec.FileName=onDiskName` makes any
  "pick a saved file" UI show opaque token names. Only set it when blank.
- **The adapter must BOOT with its `FilePath` already set.** `SetItemSettingValue`
  did NOT reliably persist the path to the definition (`GetItemSettingValue` kept
  returning `""`), so the service polled nothing. The robust fix is a service
  `OnInit()` that sets `..Adapter.FilePath`/`ArchivePath` from a known config
  global when blank — guaranteed to apply when the service job boots:
  ```objectscript
  Method OnInit() As %Status {
      set d=$get(^MyApp.Config("dataDir"))
      if d'="" { if ..Adapter.FilePath="" set ..Adapter.FilePath=##class(%File).NormalizeDirectory(##class(%File).NormalizeDirectory(d)_"specs") }
      quit $$$OK
  }
  ```
  This sidesteps the SetItemSettingValue-doesn't-persist quirk entirely. Still
  restart the production (stop+start, not just UpdateProduction) after changing
  the data dir so OnInit re-runs.

## Portal deep-links

```
<scheme>://<host>:<port>/csp/<namespace-lower>/EnsPortal.ProductionConfig.zen?PRODUCTION=X.Setup.Production
<scheme>://<host>:<port>/csp/<namespace-lower>/EnsPortal.VisualTrace.zen?SESSIONID=<sessionId>
```
All interop messages of one job share a `SessionId` (read it in a BP via `..%SessionId`).

## Production lifecycle gotchas

- After a container/instance restart the production may report
  `ErrProductionNotShutdownCleanly` — call `##class(Ens.Director).CleanProduction()`
  then `StartProduction`.
- A half-started/hung production can hold `^Ens.Runtime` →
  `ErrCanNotAcquireRuntimeLock`; a clean container restart clears it.
- Changing item settings then `UpdateProduction()` applies most settings live, but
  some adapters (File inbound) need a full stop/start (see above).
