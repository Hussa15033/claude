---
name: dtl-generation
description: Generating, compiling, and verifying InterSystems DTL (Data Transformation Language) for HL7 v2 messages — including spec-driven generation and an LLM generate→compile→verify→auto-repair loop. Use when writing DTL classes, transforming HL7 v2, building/repairing an LLM prompt for DTL, escaping XML in DTL attributes, capturing the full compile-error log, comparing transform output, or debugging silently-failing assigns. Captures DocType, segment-path, MSH-offset, repeating-field, grouped-segment and XML-entity gotchas proven against IRIS for Health.
---

# Generating & verifying HL7 v2 DTL

How to make InterSystems DTL classes that compile AND produce the right output —
and how to drive an LLM to generate them reliably. Every gotcha was proven live
on IRIS for Health 2026.1.

## Prerequisite: IRIS for Health, not plain IRIS

`EnsLib.HL7.*` ships in **IRIS for Health** (`intersystemsdc/irishealth-community`),
NOT in `iris-community`. `Ens.DataTransformDTL`, `EnsLib.HTTP.OutboundAdapter`,
`%Net.HttpRequest` exist in both. HL7 schemas 2.1–2.8.2 are preinstalled.

## The DTL class shape that compiles

```
Class X.Y Extends Ens.DataTransformDTL [ DependsOn = EnsLib.HL7.Message ]
{
XData DTL [ XMLNamespace = "http://www.intersystems.com/dtl" ]
{
<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message'
           sourceDocType='2.3:ADT_A01' targetDocType='2.5:ADT_A01'
           create='copy' language='objectscript'>
  <assign value='"EPIC"' property='target.{MSH:3.1}' action='set'/>
  <if condition='source.{PID:8}="F"'><true>
    <assign value='"2"' property='target.{PID:8}' action='set'/></true></if>
</transform>
}
}
```

- `create='copy'` passes the whole message through, then you `<assign>` only the
  changed fields. Use `create='new'` only when building from scratch (it yields a
  SPARSE message — only assigned fields exist).

## Gotcha 1 — DocType is the message STRUCTURE, not the trigger event

`##class(EnsLib.HL7.Schema).ResolveSchemaTypeToDocType("2.3","ADT_A08")` returns
**`2.3:ADT_A01`** — in HL7 2.3 an A08 uses the ADT_A01 structure. A DTL with
`sourceDocType='2.3:ADT_A08'` **compiles but every path-based `<assign>` silently
does nothing** (DTL assigns are wrapped in Try/Catch that swallow path errors).
Always resolve the real DocType before pinning it:

```objectscript
set doc = ##class(EnsLib.HL7.Schema).ResolveSchemaTypeToDocType(version, type_trigger)
```
Derive `version`/`type`/`trigger` from the raw MSH (see Gotcha 5), e.g. ORU_R01 → `2.3:ORU_R01`.

## Gotcha 2 — repeating fields REQUIRE a repetition index

`PID:5(1).1.1` works; `PID:5.1.1` reads/writes empty. A missing index is **not a
compile error** — it just misses. Don't tell an LLM it's a compile error.

## Gotcha 3 — segments inside groups need the group path

In ORU_R01, PID is nested: read/write via `PIDgrpgrp(1).PIDgrp.PID:3(1).4`, NOT
bare `PID:3...`. ADT messages have PID/PV1 at top level so bare paths work there.
Discover the group prefix by trying it against the live schema.

## Gotcha 4 — `OutputToString()` appends a trailing segment terminator (CR)

Always normalize before exact-comparing to an expected message: translate LF→CR
and strip trailing CR. This was the entire 1-char diff in testing.

## Gotcha 5 — reading MSH-9/MSH-12 to derive the DocType (chicken-and-egg)

`GetValueAt("MSH:9.1")` needs a DocType already poked. To DERIVE the DocType,
parse the raw MSH string instead (MSH-1 is the field separator, so):
`set msh=$piece(raw,$c(13),1), type^trig=$piece(msh,"|",9), version=$piece(msh,"|",12)`.

## Compile + run + verify loop (the core mechanic)

```objectscript
// compile from an in-memory string (no temp file needed):
set st=##class(%Stream.GlobalCharacter).%New() do st.Write(classSource)
set sc=$system.OBJ.LoadStream(st,"ck/displayerror=0/displaylog=0",.err)
//   $$$ISOK(sc) ? GetErrorText gives line# + generated source line.
// parse HL7 (segments joined by $c(13)) and poke the DocType:
set msg=##class(EnsLib.HL7.Message).ImportFromString(raw,.sc)  do msg.PokeDocType("2.3:ADT_A01")
// run + serialize:
set sc=$classmethod(cls,"Transform",msg,.out)  set outStr=out.OutputToString()
```

For comparison, score over **expected-populated fields only** (a `create='new'`
output is sparse — comparing against a full expected message floods false
"MISSING" diffs). Handle the MSH off-by-one: MSH-1 is the separator, so when
splitting a segment on `|`, MSH field N = `$piece(seg,"|",N)` but for other
segments field N = `$piece(seg,"|",N+1)`.

## Driving an LLM to generate DTL

- **System prompt**: give the exact class shape above, the `{SEG:field(rep).comp.sub}`
  brace grammar, the repetition-index and grouped-segment rules, the XML-entity
  escaping rule (see "#1 compile-failure cause" below — put it in the system prompt
  AND the repair prompt), and "output ONLY a complete class (a ```objectscript
  fence is ok), no prose."
- **Pin** source/target DocTypes in the user prompt (resolved per Gotcha 1).
- **Caveat handling**: tell it the example output may not be the literal transform
  of the input; infer general rules, don't hard-code instance-specific values.
- **Feedback loop**: on compile failure feed back the FULL decomposed error log
  (see "Capture the FULL compile error log" — not just the top `GetErrorText`
  wrapper) and auto-repair (see "Auto-repair loop"). On mismatch feed back a
  field-level diff, marking values not present in the source as "likely
  illustrative — don't hard-code."
- **SECURITY**: never compile the LLM's class wrapper verbatim — a smuggled
  `[ CodeMode = generator ]` method runs arbitrary code at compile time. Extract
  only the `<transform>...</transform>` fragment and re-wrap it yourself under a
  forced `DTL.Generated.*` name.

## Spec-driven generation (inputs only, NO expected outputs)

The most robust real-world model: the transformation is defined by a **written
specification**; you only have example **input** messages, never expected outputs.

- The LLM gets: the spec + the example inputs. The plan and the DTL are derived
  ENTIRELY from the spec ("there are NO example output messages; infer the output
  from the spec").
- **Verification gate = compile + run** on a primary input (the `CompileRun`
  policy) — there's nothing to diff against, so success means "compiles and
  transforms the example input without error", not an exact match.
- After acceptance, **transform every stored input** with the final DTL so the
  user can review the produced outputs.
- **Feedback loop without expected outputs:** the user reviews a produced output,
  optionally EDITS it to the desired result, and/or adds plaintext feedback. Feed
  back `{input, produced, corrected, feedback}` as the next turn ("update the DTL
  so it produces the corrected output for this input, and generalise the rule"),
  regenerate, recompile under the stable name, and re-transform all inputs. A
  "live test" (arbitrary input → output → correct+feedback) uses the same path.
- Keep the user's example inputs in a global keyed by job id so transform-all and
  the prompt's "inputs block" can reuse them.

### Spec from an uploaded document → convert to Markdown
When the spec is an uploaded file (PDF/DOCX/…), convert it to **Markdown** before
giving it to the LLM — headings/tables/lists survive and the model parses a
structured spec far better than a flat text dump:
- **DOCX / DOC / HTML / ODT / RTF / EPUB → Pandoc** (`pypandoc.convert_file(path,
  "gfm", extra_args=["--wrap=none"])`). If no system `pandoc` is on PATH,
  `pypandoc.download_pandoc()` fetches a private copy (works in a bare container).
- **PDF → `pdfplumber`** (emits page text + tables as Markdown pipe-tables), with
  **`pypdf`** as the text-only fallback. Pandoc cannot read PDF — never route PDF
  through it.
- Always keep a last-ditch plain-text read so a converter failure still yields
  usable content instead of a hard error.

### Big specs WILL overflow %String — use a %Stream
A real spec document (e.g. a 46-page HL7 guide) easily exceeds **32 000 chars**,
so a `%String(MAXLEN=32000)` property raises `ERROR #7201/#5802 … length longer
than MAXLEN allowed of 32000` the moment you `%Save()`. Hold the spec (and the
extracted document text) in a **`%Stream.GlobalCharacter`** property, write via
`do obj.Prop.Write(text)`, read via a `StreamStr()` helper, and surface it to JSON
by reading the stream. (When you flip a persistent property String→Stream you must
`%KillExtent()` the old rows — the stored layout changed — and **restart the
production** so business hosts drop their stale compiled code; the event-log line
"continuing to run using code from previous version" is the tell that a service is
still running the old String-typed version and silently mis-storing data.)

### Earlier model (kept for reference): unmatched example pairs
If you DO have example outputs but they're not reliable pairs, treat inputs and
outputs as two independent lists, pick one primary input + one primary output for
the gate, and tell the model the examples are "NOT necessarily matched pairs —
infer the general rules; do not assume input[i] maps to output[i]."

## Give the LLM a TESTED DTL element/attribute schema (not just an example)
A single example `<transform>` isn't enough — the model invents elements/attributes
that don't exist and gets "Invalid DTL". Put a concise, **compile-verified**
element reference in the system prompt (and repeat it in the compile-repair prompt).
The valid DTL elements, each confirmed by compiling them live on IRIS for Health:
- `<transform>` (root, one): `sourceClass`/`targetClass='EnsLib.HL7.Message'`,
  `sourceDocType`/`targetDocType='ver:struct'`, `create='copy|new|existing'`,
  `language='objectscript'`. Holds a flat ordered list of the actions below.
- `<assign value='EXPR' property='target.{PATH}' action='set|append|clear|insert|remove' [key='EXPR']/>` — self-closing.
- `<if condition='OBJECTSCRIPT-BOOL'><true>…</true><false>…</false></if>` (`<false>` optional).
- `<switch><case condition='BOOL'>…</case><default>…</default></switch>`.
- `<foreach property='source.{REPEATING()}' key='k'>…</foreach>` — use the key as the rep index inside.
- `<code><![CDATA[ valid ObjectScript ]]></code>` — escape hatch.
- `<trace value='EXPR'/>`.
- `<comment/>` — **must be empty/self-closing**; text content inside `<comment>` is INVALID.
Tell it to use ONLY these, invent no attributes, and never leave a tag unclosed.
Authoring tip: actually compile each element form (via the compile-from-string
path) before writing it into the prompt — that's what makes the schema trustworthy.

## Give the LLM the ACTUAL HL7 message schema (segment paths + field numbers)
A tested DTL element schema makes the DTL *compile*; it does not make it *correct*.
The model still invents segment paths, wrong group prefixes, missing repetition
indexes, and non-existent field numbers — which COMPILE fine but silently produce
no output (DTL wraps path assigns in Try/Catch). The fix is to inject the real
message structure for the source (and target) DocType, read live from the IRIS HL7
schema store, into the prompt. IRIS already stores every 2.x schema; pull it with:
```objectscript
do ##class(EnsLib.HL7.Schema).GetContentArray(.c,"source","2.5:ORU_R01",,0,0)
```
`GetContentArray` returns the full structure tree: top-level `c(i,"name")`/`c(i,"type")`
where `type` is `SS:ver:SEG` for a segment, `grp`/`grp()` for a group; groups recurse
into numeric children (`c(i,j,…)`); a trailing `()` on a name marks a REPEATING
segment/group/field; each segment node carries its fields inline as `c(…,f,"name")`.
Walk it to emit (a) the exact brace path to every segment WITH its group prefix and a
concrete repetition index — e.g. `{PIDgrpgrp(1).PIDgrp.PID:...}` — and (b) per segment
`field# = FieldName`. Render it into the plan, initial-generation, and runtime-repair
prompts (see `DTL.Util.HL7Schema.SchemaText` / `PromptBuilder.SchemaBlock`). Only emit
the target schema separately when it differs from the source. This is what turns
"compiles but wrong" into "compiles and writes the right fields".
- **Gotcha — name indirection does NOT resolve a ByRef local-array parameter across
  method frames.** A recursive walk that passes `.array` and builds `@("arr("_node_")")`
  refs silently reads empty. Copy the content array into a **process-private global**
  (`merge ^||X = tC`) first and indirect on THAT (`@("^||X("_node_")")`) — PPG
  indirection works across frames. Kill the PPG when done.

## #1 compile-failure cause: unescaped XML chars inside attribute values
DTL attributes are SINGLE-quoted (`value='…'`, `condition='…'`), so any special XML
char inside the value must be an ENTITY, not the literal — else the attribute
terminates early and you get a SAX/parse error or a truncated-attribute compile
failure. This bites constantly because ObjectScript's **not-equal operator is an
apostrophe** (`'=`), and string literals need double-quotes (`"EPIC"`):
`'`→`&apos;`, `"`→`&quot;`, `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`.
- INVALID: `<if condition='source.{PID:8}'="F"'>` (bare `'` and `"` break it)
- VALID:   `<if condition='source.{PID:8}&apos;=&quot;F&quot;'>`
- A literal "set MSH-3 to EPIC" is `value='&quot;EPIC&quot;'`.
Put this rule in the SYSTEM prompt AND restate it in the compile-repair prompt
(keep it as one reusable block, e.g. `PromptBuilder.XmlEscapingRule()`), and tell
the model that a SAX / unexpected-`'` / truncated-attribute error is almost
certainly an unescaped char.

## Let the plan EXTEND the spec without contradicting it
For spec-driven planning, tell the model the **specification is authoritative**
(every rule it states must appear; never contradict it) but it MAY add sensible
extra steps it infers from the example INPUT (normalisations, derived/version
fields, cleanups) PROVIDED they don't conflict with the spec — and mark each
inferred item ` (suggested)` so the reviewer can distinguish spec-mandated from
inferred changes.

## Capture the FULL compile error log (not just the %Status wrapper)
`$system.Status.GetErrorText(tSC)` renders only the **top** wrapper of a compound
status — for a DTL that fails compilation that's the near-useless
`<Ens>ErrInvalidDTL: Invalid DTL` / `#5490 Error running generator for method
GetSourceDocType…`, with the REAL reason (a `#1011 Invalid name`, `#1001 Missing
closing quotation mark`, `#1063 Invalid TRY`, etc., with the offending generated
line + offset) buried in the nested errors. The LLM can't fix what it can't see.
Capture BOTH sources and merge them into a numbered, de-duplicated block:
- `$system.OBJ.LoadStream(stream, "ck/displayerror=0/displaylog=0", .errLog)` —
  pass an errorlog array byref and walk every node (`$order`), normalising each:
  render it via `GetErrorText` ONLY when `$listvalid(node) && $system.Status.IsError(node)`,
  else use the node text verbatim (otherwise a plain-text node gets wrongly
  re-wrapped as `#5034 Invalid status code structure`).
- `$system.Status.DecomposeStatus(tSC, .errs)` — explodes the compound status into
  every constituent error so each `#nnnn` shows up as its own line.
Clean each line (collapse CRLF/tabs, strip a leading `>` continuation marker) and
dedup across both sources. This routinely turns one opaque line into the four real
syntax errors the model then fixes in the next auto-repair round. Hand the LLM the
**complete** block (the truncated one-line UI summary is separate).

## Auto-repair loop: feed compiler/runtime errors back to the LLM
Generated DTL frequently fails to compile on the first try (unclosed XML
attribute, bad macro, missing repetition index). Don't surface that to the user —
**self-correct automatically**: on `COMPILE_FAIL`/`RUNTIME_FAIL`, append the
**verbatim** ObjectScript errors (the `GetErrorText` line numbers + offending
generated line) as a new user turn and regenerate, looping until it compiles+runs
or `MaxAttempts` is hit. Record each round as its own attempt so the UI shows the
repair chain (attempt 1 COMPILE_FAIL → "auto-correcting →" → attempt 2 SUCCESS).
Keep the verbatim errors AND a short "DTL validity checklist" in the repair prompt
(the usual causes: must be one class in the exact `Ens.DataTransformDTL` shape;
`<transform>` needs sourceClass/targetClass/DocTypes/create/language; every
`<assign>` needs value+property+action; literal values double-quoted inside the
single-quoted `value='…'`; brace paths `{SEG:field(rep).comp.sub}` with rep index;
no extra methods/`[CodeMode]`). The loop only pauses for the user once it
compiles+runs (spec-driven `CompileRun` gate) or the budget is exhausted.

## Multi-provider LLM backend (OpenAI / Bedrock / mock)
The generate→compile→repair loop is provider-agnostic — the same prompts work
against OpenAI chat-completions, AWS Bedrock Claude (Anthropic Messages format),
and an offline scripted mock. Keep the wire-format differences in ONE business
operation (host/path/body/response per provider), thread the per-job provider +
model + key (+ Bedrock region) on the request message, and the DTL loop stays
identical. See the iris-interop-rest skill for the Bedrock request/response shape
and the bearer-token auth.

## Surface PROVIDER errors descriptively (don't echo the raw transport status)
A bad model id / key shows up as `<Ens>ErrHTTPStatus: non-OK status 400`, which is
useless to a user. Parse the provider's error JSON
(`{"error":{"message","type","code"}}`) and build an actionable message: status
code FIRST (401→auth, 403→access, 404→wrong model/path, 429→rate/quota, 5xx→
transient), THEN the model-specific case (`code="model_not_found"` or message
"does not exist / do not have access" → name the bad model and tell them to reload
the model list). Branch on the **HTTP status, not the `type`** — OpenAI tags a
bad-model 400 with `type:"invalid_request_error"`, the same type it uses for a 401,
so keying off the type alone mislabels auth failures. A non-2xx also surfaces via
the hosted `EnsLib.HTTP.OutboundAdapter` as an *error status* from
`SendFormDataArray` (not just a populated response) — read the body off `tHttpResp`
in that error branch too, and prefer the parsed JSON over the transport text.

## Success policies (handling "output may not be literal")

`CompileOnly` < `CompileRun` (objective gates) < `CompileMatch` (exact, after
normalization) < `CompileMatchTolerance` (score ≥ threshold, ignoring volatile
MSH-7 time / MSH-10 control id). Add cycle (identical-candidate) and plateau
(no-score-improvement) guards so the loop can't burn the whole attempt budget on
an unsatisfiable pair.
