---
name: dtl-generation
description: Generating, compiling, and verifying InterSystems DTL (Data Transformation Language) for HL7 v2 messages — including with an LLM in a generate→compile→verify→regenerate loop. Use when writing DTL classes, transforming HL7 v2, building an LLM prompt for DTL, comparing transform output, or debugging silently-failing assigns. Captures DocType, segment-path, MSH-offset, repeating-field and grouped-segment gotchas proven against IRIS for Health.
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
  brace grammar, the repetition-index and grouped-segment rules, and "output ONLY
  a complete class (a ```objectscript fence is ok), no prose."
- **Pin** source/target DocTypes in the user prompt (resolved per Gotcha 1).
- **Caveat handling**: tell it the example output may not be the literal transform
  of the input; infer general rules, don't hard-code instance-specific values.
- **Feedback loop**: on compile failure feed back the verbatim `GetErrorText`
  (line numbers + offending line). On mismatch feed back a field-level diff,
  marking values not present in the source as "likely illustrative — don't
  hard-code."
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

### Earlier model (kept for reference): unmatched example pairs
If you DO have example outputs but they're not reliable pairs, treat inputs and
outputs as two independent lists, pick one primary input + one primary output for
the gate, and tell the model the examples are "NOT necessarily matched pairs —
infer the general rules; do not assume input[i] maps to output[i]."

## Success policies (handling "output may not be literal")

`CompileOnly` < `CompileRun` (objective gates) < `CompileMatch` (exact, after
normalization) < `CompileMatchTolerance` (score ≥ threshold, ignoring volatile
MSH-7 time / MSH-10 control id). Add cycle (identical-candidate) and plateau
(no-score-improvement) guards so the loop can't burn the whole attempt budget on
an unsatisfiable pair.
