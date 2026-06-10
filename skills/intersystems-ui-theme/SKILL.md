---
name: intersystems-ui-theme
description: Building a browser UI with an InterSystems / IRIS look-and-feel — light enterprise app-shell (dark-blue sidebar + KPI cards), light, dark+glassmorphism, Material matte, or dark blue-forward flat — served same-origin by IRIS from a CSP static web application. Use when creating a front-end for an IRIS app, theming with InterSystems colours (blue #343699 / green #00b6b0, or green #1a8f6c / IRIS blue #2596be)/logo, choosing dark vs light, building a sidebar+workspace app-shell with KPI cards / progress bars / a mapping table / a validation checklist, deriving a REST API base path from the UI path, polling a long-running IRIS job, rendering a build progress bar with an elapsed timer, markdown-rendering an LLM-returned plan, line-numbering code boxes, line-diff highlighting, copy buttons, a tabbed working pane, a saved-artifact picker + reader modal, an editable LLM plan, rendering a side-by-side HL7/text diff (scroll-synced panes, red-removed/green-added char highlighting), giving async action buttons a spinner busy state, building a human-in-the-loop review gate (original-vs-structured side-by-side with provenance highlighting, an accuracy-gate verdict card, an extraction-confidence badge), or markdown-rendering an LLM plan. Includes palettes, logo URL, and a self-contained single-file SPA pattern.
---

# InterSystems-themed web UI (served by IRIS)

A portable recipe for a single-file SPA that looks like an InterSystems product
and is served by IRIS itself (same-origin as the REST API, so no CORS).

## Palette & logo

InterSystems IRIS primary brand colour is **`#2596be`** (IRIS blue). The broader
InterSystems brand also uses a deep **blue `#343699`** + **teal-green `#00b6b0`**
pairing (see the light enterprise variant below) — both are "correct"; pick one
pairing and stay consistent.

**Light ENTERPRISE app-shell variant** (the current "InterSystems AI DTL Generator"
look — a dark-blue sidebar + soft-grey workspace + white bordered panels; blue for
nav/headings/primary actions, green for active/approval/success/progress). This is
the most "product-grade" of the variants; lead with it for a dense form-based
developer tool. Full palette:
```css
:root{
  --iris-blue:#343699; --iris-green:#00b6b0;
  --iris-blue-900:#17194f; --iris-blue-800:#242679;        /* sidebar / hovers */
  --iris-green-100:#dffaf8; --iris-green-700:#0a6d68;       /* green chips / text-on-light */
  --ink:#1b2240; --muted:#66708f; --soft:#f5f7fb; --paper:#fbfcff; --panel:#fff;
  --line:#dfe4f0; --line-strong:#c8d0e3;                    /* borders */
  --radius-lg:18px; --radius-md:12px; --radius-sm:9px;      /* sharp-but-not-playful */
  --shadow:0 10px 28px rgba(28,34,69,.07);                  /* soft, not heavy */
}
```
Essentials, load **Inter + Roboto Mono** from Google Fonts:
- **App shell** = `display:flex` with a fixed **240px dark-blue sidebar** (`--iris-blue-900`,
  `position:sticky;height:100vh`) holding brand + nav + a footer health pill, and a
  flex `main` workspace. Nav links are full-width text buttons; the active link gets
  `box-shadow:inset 3px 0 0 var(--iris-green)` + a faint green gradient wash. This
  REPLACES the right-pane tab bar — `showView(v)` toggles `.active` on
  `.navlink[data-view=v]` and `#view-v` (same mechanic, sidebar instead of tabs).
- **Panels**: white, `1px var(--line)` border, `--radius-lg`, `--shadow`. Borders +
  soft shadow, NOT glass, NOT gradients-on-surface.
- **KPI cards** (top of the workspace): white card, `1px` border, soft shadow, a 4px
  **gradient top-strip** `linear-gradient(90deg,var(--iris-green),var(--iris-blue))`
  (a `::before`), a small uppercase muted label, a large 20px value, a muted status
  line. A `setKpi(idx,val,sub)` + `updateKPIs(job)` keeps them mirroring the live job
  (Status / Attempts / DocType / Model). Use `repeat(4,1fr)`, collapse to `repeat(2,1fr)`.
- **Buttons**: primary = filled `--iris-blue`; **ok/approval = filled `--iris-green`**;
  ghost = white + `--line-strong` border; danger = white + red border. All `--radius-sm`.
- **Inputs**: white, `1px --line-strong`, green focus ring `box-shadow:0 0 0 4px rgba(0,182,176,.13)`.
- **Status chips**: `b-SUCCESS`→green-100/green-700, `b-AWAITING_*`→amber, `b-RUNNING/GENERATING`→
  blue tint, `b-FAILED/REJECTED`→red tint.
- **Light-chrome / dark-code split (deliberate):** keep the diff/DTL/LLM-message
  viewers on a **dark code surface** (`--code-bg:#0e1430; --code-fg:#e9fbff;
  --code-line:#252c54; --code-head:#161d44`) even though the rest of the app is light —
  monospace HL7/DTL reads best on dark, and it visually separates "generated code"
  from "chrome". Re-tune the diff highlight alphas to the dark surface (~0.18 line
  tint, ~0.5 char highlight) — the light-theme alphas wash out on `#0e1430`.
- A "Mapping table" (Source→Target→Confidence), "AI mapping plan" numbered step list,
  "Validation checklist" (green check rows + amber needs-review rows), and gradient
  "Progress bars" (`linear-gradient(90deg,var(--iris-blue),var(--iris-green))` fill on
  an `#e7edf7` track) are all on-brand components for this shell.
- **Responsive**: collapse the workspace grid to one column < ~1180px, KPIs to 2-up,
  and flip the sidebar to a horizontal scrolling bar < ~880px.

Light palette (simpler, panel-on-page, IRIS-blue):
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
"auto-correcting →", and show `lastError` prominently). An "LLM messages" view
gives full visibility into the model conversation: the job already persists the
whole transcript (system/user/assistant turns), so expose it via
`GET /jobs/{id}/messages` and render each turn as a collapsible card colour-coded
by role (system=muted, user→OpenAI=blue, assistant←OpenAI=green), with a char
count, a copy button, the long system prompt collapsed by default, and an opt-in
2s auto-refresh while a job is running. This is what unblocks a user debugging "the
LLM keeps failing" — they can read exactly what was sent and returned.

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

## Line numbers on every code / message / transcript box
For an HL7/DTL/LLM-transcript tool, line numbers make errors ("line 3 offset 81")
navigable. Two cheap vanilla helpers, no library:
- **read-only blocks** (`linedBlock(text)` → a `.lined` flex div = a right-aligned
  `.gut` gutter holding `1\n2\n…\nN` beside a `.code` div with the text). Use it for
  DTL source, class source, input/output messages, and each LLM message body.
  Key CSS: gutter and code share `line-height` so rows align; `.code` is
  `white-space:pre-wrap;word-break:break-word`.
- **editable textareas** (`lineNumberTextarea(ta)`): wrap the textarea next to a
  `.gut` div, recompute the gutter on `input`, and sync `gut.scrollTop=ta.scrollTop`
  on `scroll` (and after input) so the numbers track wrapping/scrolling. Guard with
  a `data-lined` flag so re-renders don't double-wrap.
Match the gutter's font/size/line-height to the content exactly or the numbers
drift from their rows.

## Dark mode, InterSystems-BLUE forward
The IRIS blue `#2596be` (lighter accent `#56c2e6`) as Material `--primary` over a
deep blue-ink dark surface set reads strongly as "InterSystems". Dark palette that
worked: `--bg:#0b1620; --surface:#10212d; --surface-2:#152734; --surface-3:#1d3645;
--txt:#e6f1f7; --muted:#8fa9b8; --outline:#2c4757; --outline-v:#223a48`, with
`--primary-cont:#0c3a4c/--on-primary-cont:#bfe9f7` for chips. Gotchas migrating a
light theme to dark: gutter/inset backgrounds that used `rgba(0,0,0,.03)` vanish on
dark — flip to `rgba(255,255,255,.04)`; the dark code block (`.dtl`) needs a real
border now that it no longer contrasts with a white page; bump shadow alpha
(`rgba(0,0,0,.35)`). Watch for typos when hand-editing the `:root` line — a stray
duplicate or non-ASCII char silently kills every var after it.

## Copy buttons everywhere (one tiny helper)
`copyBtn(getText)` returns a button that copies `getText()` (string or fn) via
`navigator.clipboard.writeText` with a `document.execCommand('copy')` textarea
fallback, flips to "copied ✓" for ~1.2s. Drop it into every code/message/output
header (input, output, DTL source, class source, each LLM message, live output, the
spec-reader modal). `e.stopPropagation()` so a copy click inside a collapsible
header doesn't also toggle it.

## Line-level diff highlighting on a line-numbered block
Extend the line-number renderer to take a per-line class array. An LCS line diff
(`lineDiff(a,b)` → `{aCls,bCls}` of `'add'|'del'|'chg'|''`) drives it: render each
line as its own `<span class="ln add|del|chg">` (and a matching gutter
`<span class="gl …">`), colouring add=accent, del=red, chg=amber with a 3px
left-border. Show input with `aCls` and output with `bCls` so a transform's changes
are visible on both sides while line numbers stay intact. **Pair adjacent del/add
runs into `chg`** as a post-pass over the raw LCS walk — otherwise a modified line
shows as a red delete on the left and an unrelated blue add on the right, which
doesn't read as "this line changed". Walk both class arrays together; where a `del`
on the left lines up with an `add` on the right, retag both `chg` (amber). Add a
small colour legend (changed / only-in-input / only-in-output) so the highlighting
is self-explanatory.

## Character-level diff inside a changed line
Line-level add/del/chg highlighting tells you WHICH lines changed; a per-character
diff on the paired `chg` lines tells you WHICH CHARACTERS. After pairing a del/add
run into `chg`, run a second LCS — this time over the two lines' CHARACTERS — to get
`{aSeg,bSeg}`: arrays of `{t,c}` runs where `c` is `""` (kept), `"cdel"` (removed,
shown on the input side) or `"cadd"` (added, shown on the output side). Render a
changed line as a sequence of `<span>`s instead of plain text, classed by `c`, so
e.g. `OLDAPP`→`NEWAPP` highlights only `OLD`/`NEW`. Merge adjacent same-class chars
into one run, and cap the O(n·m) table for very long lines (fall back to
whole-line). Colour `cdel`/`cadd` with a STRONGER background than the line tint
(~0.4 alpha vs ~0.15) so the exact chars pop against the already-tinted chg line.
Thread the seg arrays through the line-numbered renderer alongside the per-line
classes (`linedBlock(text,classes,segs)`).
- **Colour convention: removed=red, added=GREEN (not blue).** Don't use a blue
  accent for "added" — in a transform diff blue reads as a neutral info accent, while
  users expect git-style red-removed / green-added. Use the **InterSystems green** for
  `cadd` AND the line-level `add` tint+gutter, keep red for `cdel`/`del`, and amber for
  `chg`. The exact green rgba depends on the theme + surface: on the light Material
  green theme it was `rgba(26,143,108,…)`; on the **light-enterprise dark-code surface**
  it's `rgba(0,182,176,…)` (`--iris-green`) at ~0.18 (line) / ~0.5 (char) so it pops on
  `#0e1430`. Update EVERY place the colour appears together or the legend drifts from
  the render: the `.cadd` char highlight, the `.ln.add` line background, the `.gl.add`
  gutter number, the `.difflegend .lg.add::before` swatch, AND any inline-styled
  swatch in the legend HTML (an `rgba(...)` hardcoded in a `<span style>` won't follow
  a CSS-var change — grep the raw rgba literal, not just `var(--…)`).

## Scroll-sync the two side-by-side diff panes
A side-by-side input/output diff is only readable if the two panes scroll together —
otherwise the user scrolls one pane and loses the alignment they came to see. Add a
tiny `syncScroll(els)` helper that binds a `scroll` listener on each container and
mirrors `scrollTop` AND `scrollLeft` to the others (HL7 lines are long — horizontal
sync matters as much as vertical). Guard against the listeners ping-ponging with a
re-entrancy flag (`let lock; if(lock)return; lock=true; …; lock=false`). Make it
idempotent so a poll re-render can re-bind cleanly — stash the handler on the element
(`el._scrollSync`) and `removeEventListener` the old one before adding the new. The
scroll container is the element with `overflow:auto` — for an `.io>.side` grid that's
the `.side` wrapper, not the inner `#dexp`/`#dact` content div, so sync
`$("#dexp").closest(".side")`, not `#dexp` itself. Call it once after each diff
render (the accept/reject box and every per-output pair in the Outputs list).

## Give async action buttons a busy state (spinner + disable)
Any button that fires a request and then waits — Approve/Reject a plan, Accept/Reject
an attempt, rebuild — must show that something is happening or the user re-clicks.
Reuse the same `.spinner` pattern already on the generate button: a `busyBtn(btn,
label, fn, siblings)` helper that swaps the button's innerHTML to
`'<span class=spinner></span> '+label`, disables it AND its sibling (so you can't
Approve then Reject the same gate), runs `fn`, and on a thrown error restores the
saved innerHTML/disabled of all of them. No restore on success is needed when the
action triggers a poll that re-renders the whole pane (`startPolling()`); the spinner
just bridges the gap until the first tick repaints. Give each action a contextual
label ("Building…", "Transforming all…", "Regenerating…", "Revising…") rather than a
generic "Working…".

## Stop the poll from flashing the UI
A `setInterval` poll that re-renders by `innerHTML=""`+rebuild every tick makes
boxes (status, diff, copy buttons) visibly flash — the DOM is torn down and
recreated even when nothing changed. Two fixes, both needed:
1. **Dedupe renders with a content signature.** Build a string of everything the
   view actually paints (`status`, `verdict`, attempt list, the diffed messages,
   the DTL, `lastError`, …); if it equals the previous tick's signature, `return`
   without touching the DOM. Apply the same trick to any opt-in auto-refresh list
   (LLM messages): sign on `role+contentLength` per message and skip the rebuild.
2. **Stop polling at rest states.** The server won't advance `AWAITING_PLAN` /
   `AWAITING_ATTEMPT` (waiting on the user) or terminal `SUCCESS`/`FAILED`/
   `REJECTED` on its own — `clearInterval` there instead of polling forever.
A multi-provider key form: generalise `isOpenAI()` to `needsKey()`/`isBedrock()`,
swap the key label/placeholder + a region field per provider, and preset the model
`<select>` to that provider's known ids (hide the live-model-list button where the
provider has no `/models` endpoint).

## Saved/uploaded artifacts: list + pick + read, don't re-process
Uploading + extracting a doc every run is slow. Persist each upload and add a
`GET /specs` list endpoint (`token,fileName,status,size,createdAt`); the UI offers a
third "Saved spec" mode (a `<select>` of READY, non-empty specs) so the user reuses
one without re-uploading, plus a "read full specification" link that opens the text
in a simple overlay modal (fetch `GET /specs/:token` on selection). Keep the
ORIGINAL upload filename on the record — if a file-ingest service later overwrites
it with the on-disk `<token>.ext`, the picker shows opaque names; only set it when
blank.

## Let the user EDIT an LLM plan before approving
For a plan-approval gate, let the user append their own steps (a dynamic
add/remove list of inputs) and POST them as `planAdditions[]` on approve. Server-
side fold them into the stored plan AND inject a user turn marking them as
additional REQUIRED steps so the model implements them without dropping the
original plan.

## Source-grounded review gate (original vs structured, provenance-highlighted)
When an early human checkpoint reviews an LLM-restructured artifact (e.g. a raw spec
turned into an explicit rule list), show **original on the left, structured on the
right, side-by-side**, and make each structured item **traceable to its source**:
- The server returns, per item, a `sourceQuote` (verbatim snippet it came from) + an
  `inferred` flag. Colour-code each rule by a left-border: green = grounded in
  source, amber = inferred (verify), red = NO source (possible hallucination). Show a
  small coverage summary ("✓ 4 grounded · ● 1 inferred · ⚠ 0 no-source").
- On hover of a rule, **highlight the matching snippet in the original pane**:
  rebuild that pane as text + a `<span class=provhi>` around the first
  case-insensitive match of the quote (cap the match length). On mouseleave restore
  the plain text. This lets the reviewer confirm at a glance that every rule is real
  and nothing was invented — errors caught at the cheapest point.
- Make the structured artifact **editable** (a textarea pre-filled with the markdown)
  and send the edited version back on approve (`{action:"approve-spec", specEdit}`) —
  what they approve becomes the authority downstream. Provide a reject that re-runs
  the structuring with feedback (a distinct action from rejecting a later build).

## Show the accuracy-gate verdict on the review card (informed, not blind, review)
If the backend verifies a candidate against a spec before showing it (run-all-inputs
+ field-coverage + an LLM judge — see dtl-generation), render that verdict so the
human reviews an INFORMED candidate, not a green checkmark that means "didn't
crash". A `gateReport` card: a pass/fail header (green vs amber left-border), a row
of ✓/✗ checks (runs on all inputs / actually transforms fields / spec-conformance
judge NN%), per-input "N fields changed" counts, and the judge's concrete
violations (rule + detail, severity-tagged HIGH/LOW). Colour the whole attempt card
amber when the candidate did NOT pass, green when it did, so "this needs work" reads
instantly. Fold `gateReport` (stringified) into the poll dedupe signature so it
repaints when the verdict changes.

## Extraction-confidence badge — flag low-confidence specs for review
When an uploaded doc is extracted with a confidence score + warnings (scanned PDF,
dropped tables, mojibake — see dtl-generation), surface it where the spec is picked:
a confidence badge (green ≥0.8 / amber ≥0.5 / red below) on the upload result AND in
the saved-spec `<select>` (append "⚠ NN%" to low-confidence options), plus an
expandable warning list ("likely scanned — needs OCR", "tables may not have
survived"). The goal is to make a bad extraction impossible to miss BEFORE it's used
to generate anything.

## Render an LLM plan as Markdown (some models return Markdown, not plain text)
The plan-gate text often comes back as Markdown (headings, `**bold**`, numbered
lists, fenced code). Dumping it as `textContent` shows literal `#`/`**`/backticks;
render it instead. Ship a tiny self-contained `mdToHtml(src)` (no library) covering
the subset a plan uses: ATX headings, `**`/`__` bold, `*`/`_` italic, inline `` `code` ``,
fenced ```` ``` ```` blocks, `-`/`*`/`+` and `1.` lists, `>` blockquotes, `---` rules,
`[text](http…)` links. Then `$("#plantext").innerHTML = mdToHtml(j.plan||"")`.
- **SECURITY — escape FIRST, then emit your own tags.** HTML-escape every run of
  source text (`& < >`) *before* applying any inline replacement, so the model's plan
  can never inject markup; only your own `<h*>/<strong>/<code>/…` tags reach `innerHTML`.
  (Verify with a `<script>` in a plan — it must render inert.)
- Inline order matters: replace inline **code first** so its contents aren't
  re-processed for bold/italic, then links, then bold, then italic.
- Style the rendered block under one `.plan` scope (`.mdh` headings in the brand blue,
  `code`/`pre.mdcode` monospace, `blockquote` with a green left-border) so it inherits
  the panel's look. Keep `mdToHtml` pure (string→string) so it's unit-testable by
  extracting just the md functions and exercising them in `node`/`vm` without a DOM.

## Build progress bar + elapsed timer (feedback for "Approve & build")
A button spinner (see busy-state below) covers the click→first-poll gap, but a
multi-second server build (plan→generate→compile→repair) needs sustained feedback.
When a job is in a WORKING state (`PLANNING`/`QUEUED`/`GENERATING`/`RUNNING`), render
a build card in the status pane with a gradient **progress bar** + a live **m:ss
elapsed timer**:
- Indeterminate bar (you don't know % done): a `.pfill` that animates left→right on a
  loop (`@keyframes`), gradient `linear-gradient(90deg,var(--iris-blue),var(--iris-green))`
  on an `#e7edf7` track. Determinate (you have a %): set `width:N%`.
- Timer: a `buildClock` timestamp + a 250ms `setInterval` that writes
  `fmtElapsed(Date.now()-buildClock)` into a `#buildtimer` span. Start the clock ONLY
  on a **successful** kick-off POST (`if(ok)buildClockReset()` after Plan & Generate /
  Approve & build / Reject & regenerate) — so a failed request shows the error, not a
  running timer. Stop + clear it at every terminal / awaiting-user state, alongside
  `stopPolling()`.
- The same card carries the contextual working message ("Drafting a plan…",
  "Building the DTL…", "Auto-correcting from the compiler errors…") and surfaces the
  auto-repair rounds as they stream into the attempt list above it.

## Show LLM token usage + cost in the UI
When the backend reports per-call token usage, surface it: a **usage bar** at the
top of the conversation view (this job's cost, in/out tokens, call count, model;
plus an all-time cost/token total kept server-side), and a per-message chip on
each assistant turn (`1429↓ / 127↑ tok` + `$0.0048`). Format money adaptively
(`$0`, 5dp under a cent, 4dp otherwise) and tokens as `k` for thousands. Fold the
usage figures into the auto-refresh dedupe signature so the bar updates when cost
changes but doesn't flash on no-op ticks.

## Model picker: a `<select>` populated from the provider's list endpoint
Make the model field a **`<select>`** the user must choose from — NOT a free-text
input. Both OpenAI and Bedrock expose a list endpoint that returns the exact ids the
key/account can use (Bedrock inference-profile ids included), so there's no need to
let the user type an arbitrary id, and a free-text box invites typos and unsupported
ids. The refresh button fills the `<select>` with those real ids
(`option.value=option.textContent=id`); preselect the remembered model if it's still
in the list, else the first option. (Earlier this was an `<input list=datalist>` to
allow pasting an account-specific id — the list endpoint makes that unnecessary, and
a hard `<select>` guarantees only a real, listed model is submitted.) `#go` still
guards `$("#model").value` being empty (the disabled placeholder option has `value=""`).

## Gate the model box on a valid key
Don't show speculative default model ids for a paid provider — they mislead. Keep
the model `<select>` **disabled** with a single placeholder option ("Enter a valid
API key") until the key validates, then enable it and fill it from the provider's
model-list endpoint. Validate on key blur/refresh (a successful `/models` call =
valid); reset to the placeholder option and re-disable if the key is emptied or
rejected. Disabling a `<select>` = set `.disabled` and replace `.innerHTML` with the
lone placeholder `<option value="">` (you can't set `.placeholder` on a `<select>`).

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
