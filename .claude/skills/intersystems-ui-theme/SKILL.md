---
name: intersystems-ui-theme
description: Building a browser UI with an InterSystems / IRIS look-and-feel (light OR dark+glassmorphism), served same-origin by IRIS from a CSP static web application. Use when creating a front-end for an IRIS app, theming with InterSystems colours/logo, applying glassmorphism, deriving a REST API base path from the UI path, polling a long-running IRIS job, or rendering a side-by-side HL7/text diff. Includes palettes, logo URL, and a self-contained single-file SPA pattern.
---

# InterSystems-themed web UI (served by IRIS)

A portable recipe for a single-file SPA that looks like an InterSystems product
and is served by IRIS itself (same-origin as the REST API, so no CORS).

## Palette & logo

InterSystems IRIS primary brand colour is **`#2596be`** (IRIS blue).

Light palette:
```css
:root{ --is-blue:#2596be; --is-blue-d:#1d7aa0; --is-navy:#172b46;
  --bg:#eef3f7; --panel:#fff; --panel2:#f4f8fb; --line:#d4e0ea; --txt:#172b46; --muted:#5b7088; }
```

**Dark + glassmorphism** (frosted translucent panels over a deep gradient — keep
the IRIS-blue accent):
```css
:root{ --is-blue:#2596be; --is-blue-l:#56c2e6; --txt:#e8f0f7; --muted:#8aa0b8;
  --glass:rgba(20,32,48,.55); --line:rgba(120,160,200,.18); --blur:saturate(140%) blur(14px); }
body{ color:var(--txt); background-attachment:fixed; background:
  radial-gradient(1100px 700px at 12% -8%, rgba(37,150,190,.30), transparent 60%),
  radial-gradient(900px 700px at 105% 10%, rgba(124,92,255,.18), transparent 55%),
  linear-gradient(160deg,#0a1018,#0d1420 55%,#0a121c); }
.glass{ background:var(--glass); backdrop-filter:var(--blur); -webkit-backdrop-filter:var(--blur);
  border:1px solid var(--line); border-radius:16px;
  box-shadow:0 8px 32px rgba(0,0,0,.35), inset 0 1px 0 rgba(255,255,255,.05); }
```
Glassmorphism essentials: a colourful **fixed** background gradient; panels with
`backdrop-filter: blur()` + semi-transparent fill + hairline `rgba` border + soft
shadow + a subtle inset top highlight. Keep text high-contrast (`#e8f0f7`) and use
the IRIS blue (and a lighter `#56c2e6`) for accents, primary buttons (gradient),
and active tabs. Style scrollbars to match (`::-webkit-scrollbar-thumb`).

**InterSystems GREEN-forward variant** (used by "ISC DTL Generator"): lead with
the InterSystems green `#1aa179` (lighter `#3ed29b`, dark `#0f7d5d`) as primary —
buttons, active tabs, section headings, the health-dot pulse — with IRIS blue
`#2596be` as the *secondary* accent (e.g. a "Live test" action). Layered green/
blue radial gradients over a near-black green-ink base (`#0a120f`) read as
"InterSystems" rather than a generic dark template.

**Make it feel less generic / AI-templated + add motion** (cheap, high-impact):
- A gradient-clipped title (`background-clip:text;color:transparent`).
- Subtle, purposeful animations: a gentle `floaty` logo bob, a `pulse` ring on the
  healthy status dot, `fade`/`slidein` on cards & list items as they appear, a CSS
  `.spinner` shown inside buttons during async work (Planning…/rebuilding…), and a
  1px `translateY` lift on primary-button hover. Keep durations 0.2–0.4s.
- Asymmetric, layered radial gradients (not one flat colour); rounded 13–18px
  cards with real elevation; coloured left-borders to categorise cards
  (green=ok, amber=needs-review, blue=info).

**Per-page favicon + title:** set `<title>` and
`<link rel="icon" href="https://…/favicon.jpg"/>` in `<head>` (any image URL works;
add `onerror` on logo `<img>` tags so a blocked image never breaks layout).

**Multi-view SPA:** a top tab bar swapping `.view` sections (Build / Outputs /
Live test / Classes / History) keeps everything in one file; lazy-load each view's
data when its tab is clicked. A "Classes" explorer lists `DTL.Generated.*` with
source fetched from `GET /classes`; "Outputs" lists transform-all results with an
editable output + feedback box per row.

Logo (top-left, ~32px, `onerror` hide so a blocked CDN never breaks layout):

```html
<img src="https://community.intersystems.com/sites/default/files/inline/images/iris_data_platform_cmyk_0.png"
     style="height:34px" onerror="this.style.display='none'"/>
```

## Single-file SPA, served from a CSP static app

Ship the whole app as one `index.html` (vanilla JS, no build step). Serve it from
an IRIS CSP **static** web application (see iris-interop-rest skill for the exact
`Security.Applications` settings and unauthenticated-access notes). Deploy by
copying `index.html` into the app's physical directory (e.g.
`<iris-mgr>/csp/<appname>/`).

## Derive the REST base from the UI path (no hardcoded host)

The page is served at `<app>/ui/` and the REST API is a sibling at `<app>/api`.
Derive it at runtime so it works on any host/port and tolerates `index.html` or a
bare directory URL:

```js
function deriveApiBase(){
  let p = location.pathname;
  if (/\/[^/]*\.[^/]*$/.test(p)) p = p.replace(/\/[^/]*$/, "/"); // strip filename
  p = p.replace(/\/+$/, "");
  return p.replace(/\/ui$/, "/api");
}
const APIBASE = deriveApiBase();
```

## Poll a long-running IRIS job

IRIS work (LLM calls, compiles) takes seconds. Start a job (`POST` → `{jobId}`),
then `setInterval` poll `GET /jobs/{id}` every ~1.2s, re-render on each tick, and
`clearInterval` on a terminal status. Persist user secrets (e.g. an API key) in
`localStorage` only if the user opts in; send them per-request, never store them
server-side in the job record.

## File upload as base64 JSON (avoids multipart parsing in CSP)

```js
function fileToB64(f){return new Promise(r=>{const x=new FileReader();x.onload=()=>r(x.result.split(",")[1]);x.readAsDataURL(f);});}
// POST {filename, dataBase64} -> server base64-decodes and writes the file.
```

## Side-by-side diff viewer (LCS) for HL7/text

A tiny LCS diff renders expected-vs-actual line by line with add/del/equal
classes — see the reference implementation in this repo's `ui/index.html`
(`renderDiff`/`lcs`). Normalize HL7 first: `.replace(/\r/g,"\n").replace(/\n+$/,"")`.

## Deep-link into the IRIS Management Portal

Build links to the production page and the per-job Visual Trace from the request
host (see iris-interop-rest skill); render them as a small links bar. Example
trace URL: `…/csp/<ns>/EnsPortal.VisualTrace.zen?SESSIONID=<id>`.

## Gotchas

- **CDN images may be blocked** — always add `onerror` fallbacks.
- A static CSP app needs `ServeFiles=2` (not 1); see iris-interop-rest.
- Keep everything in ONE file when you can — no bundler, trivial to `docker cp`.
