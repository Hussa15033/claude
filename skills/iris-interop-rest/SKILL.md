---
name: iris-interop-rest
description: Building IRIS Interoperability productions and %CSP.REST APIs — business services/processes/operations, the HTTP outbound adapter, FileInboundAdapter, creating CSP web apps programmatically, async dispatch into a running production, unauthenticated access, and Visual Trace deep-links. Use when wiring an Ens.Production, exposing REST endpoints, calling an external HTTP/LLM API from IRIS, ingesting files, or driving a job from a UI.
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
