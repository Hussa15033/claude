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

**Google Material Design, matte light variant** (current "ISC DTL Generator"
look — flat, professional, no glass): drop the glassmorphism and gradients
entirely and lean on Material's roles + elevation instead.
```css
:root{
  --primary:#1a8f6c; --primary-d:#136b51; --primary-c:#fff;      /* InterSystems green = Material primary */
  --primary-cont:#abf2d3; --on-primary-cont:#00391f;
  --secondary:#1f7d9c; --secondary-cont:#bfe9f7;                 /* IRIS blue = secondary */
  --bg:#f4f6f5; --surface:#fff; --surface-2:#eef1ef; --surface-3:#e6ebe8;  /* matte neutrals */
  --txt:#1a1c1b; --muted:#5b6360; --outline:#c2cac6; --outline-v:#dde3e0;
  --e1:0 1px 2px rgba(0,0,0,.3),0 1px 3px 1px rgba(0,0,0,.15);   /* Material elevation */
  --e2:0 1px 2px rgba(0,0,0,.3),0 2px 6px 2px rgba(0,0,0,.15);
  --e3:0 4px 8px 3px rgba(0,0,0,.15),0 1px 3px rgba(0,0,0,.3);
}
```
Material essentials: load **Roboto + Roboto Mono** from Google Fonts; a coloured
**top app bar** (matte `--primary`, white text, `--e2`); **filled buttons** are
fully-rounded pills (`border-radius:22px`) that gain elevation on hover (`--e1`→
`--e2`), **tonal** buttons use `--surface-2`, **outlined/danger** use a 1px border;
**filled text fields** (`--surface-2` fill, bottom border that thickens to 2px in
`--primary` on focus, `border-radius:8px 8px 4px 4px`); flat **surface** cards with
elevation (NOT borders) and a 4px coloured **top** strip to categorise; **primary
tabs** are text buttons with a 3px active underline in `--primary`; 8dp-grid
spacing. Keep matte — no `backdrop-filter`, no gradients on surfaces. Status chips
map to Material tonal container pairs (`--primary-cont`/`--on-primary-cont`,
`--warn-cont`, `--bad-cont`, `--secondary-cont`). Watch for stale CSS vars when
migrating off the glass theme — grep `var(--…)` used vs defined; a card that
switched from `border-left` to `border-top` must set `borderTopColor` in JS, not
`borderLeftColor`.

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

**Multi-view SPA:** a tab bar swaps `.view`/`.rview` sections (Progress / Outputs /
Live test / Classes / History); lazy-load each view's data when its tab is clicked.
A "Classes" explorer lists `DTL.Generated.*` with source fetched from
`GET /classes`; "Outputs" lists transform-all results with an editable output +
feedback box per row. A "Progress" view shows the live generate/auto-repair loop
(poll `GET /jobs/{id}`, render each attempt, label a failed-then-followed attempt
"auto-correcting →", and show `lastError` prominently).

**Tabs in the RIGHT working pane (not a global top bar):** a strong layout for a
"form on the left, work on the right" tool is a persistent two-column `main` grid
— the Build form fixed on the left, and the RIGHT column is itself a tabbed panel
(its own `.rtabs` header + `.rview` bodies). The left form never unmounts, so the
user fills it once while flipping right-pane tabs. Switch with a single
`showView(v)` that toggles `.active` on `.rtab[data-view=v]` and `#view-v`; have
the generate action call `showView('progress')` and "accept" call
`showView('outputs')`. Avoid the trap of juggling `display:grid/block` on a global
`.view` when you migrate from a top-bar SPA — delete the old `.topbtn`/`.view`
handlers and any `querySelector('.topbtn[...]').click()` calls.

**Flat & sharp variant** (matte, minimal-chrome): when the user wants it flatter
and sharper, drop nearly all shadows and shrink the radius. Use **one** CSS var
`--rad:4px` everywhere instead of per-element 12–22px radii; replace Material
elevation with **1px `--outline-v` borders** (a single faint `--e1:0 1px 2px
rgba(0,0,0,.12)` kept only for the rare floating element); buttons become flat
rectangles (`border-radius:var(--rad)`, color change on hover, no shadow);
categorise cards with a 3px coloured **left** border instead of elevation; tabs use
a 3px active underline. This reads as "professional tool" rather than "Material
demo" while keeping the green/blue roles.

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
