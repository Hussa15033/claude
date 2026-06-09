# DTL GenAI Framework — Synthesized Design

_Produced by a 3-proposal design panel with adversarial critique, then synthesized. Facts were re-verified against the live IRIS for Health 2026.1 container._

All facts confirmed:
- `Ens.Request`/`Ens.Response` are **persistent** (so sub-objects must be `%SerialObject` to avoid extent pollution — critique 2's A3).
- Both adapters exist; `Post` and `SendFormDataArray` both exist on the HTTP outbound adapter.
- **SSL configs count: 0** — confirms critique 1's A4: the live OpenAI path needs an SSL config created first; only the plaintext mock works offline.

I have all the ground-truth I need. Here is the synthesized, build-ready design.

---

# DTL Auto-Generation Framework — Recommended Build-Ready Design

IRIS for Health 2026.1, namespace `USER`. All classes under `DTL.*`. The architecture is the sound core shared by all three proposals: a **synchronous regeneration loop in a hand-coded `Ens.BusinessProcess`** (not BPL — critiques 1-D4, 2-A4, 3-B1 all converge here), **in-process compile/verify** (no separate BOs for compute steps), and **one LLM Business Operation** with an identical wire format for live OpenAI and an offline mock. The verifier and prompt are corrected against the live-container facts I just re-verified.

---

## 1. Component inventory

### Business hosts (in the production)
| Class | Kind | Purpose |
|---|---|---|
| `DTL.Svc.PairFileService` | BusinessService, `EnsLib.File.InboundAdapter` | Watches `inputs/`, pairs each arriving file with the identical-basename file in `outputs/`, derives DocTypes, emits `DTL.Msg.ForgeRequest`. |
| `DTL.Proc.Orchestrator` | BusinessProcess (plain `Ens.BusinessProcess`, ObjectScript `OnRequest`) | The regeneration loop: prompt → LLM → compile → run → verify → feedback, bounded by `MaxAttempts` + plateau/cycle guards. |
| `DTL.Op.LLMConnector` | BusinessOperation, `EnsLib.HTTP.OutboundAdapter` | POSTs OpenAI-format chat-completions to OpenAI **or** the local mock; extracts the class body from the response. |

### Utility classes (`%RegisteredObject`/`abstract`; called in-process by the BP — no messaging)
| Class | Purpose |
|---|---|
| `DTL.Util.Compiler` | Writes generated `.cls` to `/tmp`, `$system.OBJ.Load(...,"ck/displayerror=0",.err)`, returns line-numbered errors; deletes losers; promotes the winner. |
| `DTL.Util.Runner` | `ImportFromString` + `PokeDocType` + `$classmethod(cls,"Transform",msg,.out)` + `OutputToString()`; traps runtime errors. |
| `DTL.Util.HL7` | HL7 helpers: ordinal-path traversal, DocType derivation from MSH-9/MSH-12, segment/field enumeration. |
| `DTL.Util.Normalizer` | Canonical projection of a message: neutralize volatile fields, trim trailing empties, decode escapes — keyed by **ordinal** path. |
| `DTL.Util.Verifier` | Builds the structured diff + structural/field scores from two canonical projections; applies the success policy. |
| `DTL.Util.PromptBuilder` | Builds system / initial-user / feedback-user prompt text. |
| `DTL.Util.Extractor` | Markdown-fence strip + `Class…}` boundary slice + class-name/DocType validation. |

### Messages (`DTL.Msg.*`)
`ForgeRequest`/`ForgeResponse` (Ens.Request/Response), `LLMRequest`/`LLMResponse` (Ens.Request/Response), and **serial** sub-objects `ChatTurn`, `FieldDiff` (`%SerialObject`). Defined in §2.

### Setup / infra
| Item | Purpose |
|---|---|
| `DTL.Setup.Production` (`Ens.Production`) | Wires the three hosts + settings. |
| `DTL.Setup.Installer` (`%RegisteredObject`) | `LoadDir` of `src/DTL`, compile, create+start production, configure mock/live mode. Manifest-style classmethod `Run()`. |
| `mock/mock_llm.py` | Offline OpenAI-compatible server; scripts a **broken→corrected** DTL curriculum keyed on assistant-turn count. |
| `scripts/load_and_run.sh` | Host-side: docker cp sources, run installer, drop a demo pair, tail the trace. |

---

## 2. Message classes (exact properties)

### `DTL.Msg.ChatTurn` — `Extends %SerialObject` (embedded, NOT a message)
```
Property Role     As %String(VALUELIST=",system,user,assistant") [ Required ];
Property Content  As %String(MAXLEN=1000000);   // string, not stream: HL7+DTL turns stay well under the long-string ceiling
```
> Serial (not persistent) so it embeds in the parent's serialized body and does not create extent rows (critique 2-A3). `%String(MAXLEN=1000000)` not stream (critique 3-A3/A4: streams-in-serial + partial `Read()` are footguns; turns are far below the 3.6 MB limit).

### `DTL.Msg.FieldDiff` — `Extends %SerialObject` (embedded)
```
Property Path          As %String(MAXLEN=64);    // ORDINAL path, e.g. "2:5(1).1.1"
Property SegName       As %String(MAXLEN=8);     // "PID" — human readability in the prompt
Property Kind          As %String(VALUELIST=",MISSING,EXTRA,VALUE_MISMATCH,STRUCT_MISMATCH");
Property ExpectedValue As %String(MAXLEN=1024);
Property ActualValue   As %String(MAXLEN=1024);
Property Severity      As %String(VALUELIST=",HIGH,MED,LOW");
Property Hint          As %String(MAXLEN=512);
```

### `DTL.Msg.ForgeRequest` — `Extends Ens.Request`
```
Property JobId           As %String(MAXLEN=64);
Property InputName       As %String(MAXLEN=256);            // shared basename of the pair
Property SourceHL7       As %Stream.GlobalCharacter;        // raw input (segments \r-joined)
Property TargetHL7       As %Stream.GlobalCharacter;        // raw expected output
Property SourceDocType   As %String(MAXLEN=64);             // "2.5:ADT_A01" (derived by service)
Property TargetDocType   As %String(MAXLEN=64);
Property Instructions    As %String(MAXLEN=8000);           // optional operator intent
Property MaxAttempts     As %Integer [ InitialExpression=5 ];
Property SuccessPolicy   As %String(VALUELIST=",CompileOnly,CompileRun,CompileMatchTolerance") [ InitialExpression="CompileRun" ];
Property MatchThreshold  As %Numeric(MINVAL=0,MAXVAL=1) [ InitialExpression=0.85 ];
```

### `DTL.Msg.ForgeResponse` — `Extends Ens.Response`
```
Property JobId             As %String(MAXLEN=64);
Property Success           As %Boolean;
Property Verdict           As %String(VALUELIST=",SUCCESS,FAIL_COMPILE,FAIL_RUNTIME,FAIL_MATCH,UNSATISFIABLE");
Property GeneratedClassName As %String(MAXLEN=220);
Property AttemptsUsed      As %Integer;
Property FinalScore        As %Numeric;
Property FinalDTL          As %Stream.GlobalCharacter;      // winning (or best) class source
Property TransformedHL7    As %Stream.GlobalCharacter;      // transform(input) for the chosen DTL
Property DiffSummary       As %Stream.GlobalCharacter;      // human-readable field diff
Property LastError         As %String(MAXLEN=4000);
```

### `DTL.Msg.LLMRequest` — `Extends Ens.Request`
```
Property JobId       As %String(MAXLEN=64);
Property Attempt     As %Integer;
Property Model       As %String(MAXLEN=64);                 // blank → BO setting
Property Temperature As %Numeric [ InitialExpression=0 ];
Property MaxTokens   As %Integer [ InitialExpression=4096 ];
Property Transcript  As list Of DTL.Msg.ChatTurn;           // full accumulating conversation
```

### `DTL.Msg.LLMResponse` — `Extends Ens.Response`
```
Property JobId          As %String(MAXLEN=64);
Property Attempt        As %Integer;
Property Ok             As %Boolean;                        // HTTP 2xx + a class extracted
Property HttpStatus     As %Integer;
Property ExtractedClass As %Stream.GlobalCharacter;         // fence-stripped, ready to OBJ.Load
Property ClassName      As %String(MAXLEN=220);             // parsed from "Class X Extends..."
Property RawContent     As %Stream.GlobalCharacter;         // full assistant message (debug)
Property FinishReason   As %String(MAXLEN=32);              // stop | length | content_filter
Property ErrorText      As %String(MAXLEN=2000);
Property TotalTokens    As %Integer;
```
> The transcript lives in `LLMRequest` (critique 3's good idea): the BO is stateless, every turn is traceable in Visual Trace, the BP owns conversation state in **persistent process properties** (not locals — critique 1-D4) for safe rehydration across the sync call.

---

## 3. Control flow — `DTL.Proc.Orchestrator.OnRequest`

**Persistent process properties** (survive `SendRequestSync` dehydration): `Attempt`, `BestScore`, `BestClassName`, `BestDTL` (stream), `PlateauCount`, `LastScore`, `DTLHashes` (list of SHA-1), `Transcript` (list of `ChatTurn`).

Loop, per attempt 1..`MaxAttempts`:

1. **Build prompt turns.** Attempt 1: append `system` (static DTL grammar) + `user` (initial spec with the pair, pinned DocTypes, the caveat). Attempt k>1: append a `user` feedback turn (see "feedback payload" below). The model's prior cleaned class was already appended as an `assistant` turn at the end of the previous attempt, so the transcript is `[system, user₁, assistant₁, user₂, …]`.

2. **Call the LLM synchronously.** `SendRequestSync("DTL.Op.LLMConnector", llmReq, .llmResp, pTimeout=120)`. On transport error or `Ok=0`: record `LastError`, `Continue` (counts as an attempt). On `FinishReason="length"`: bump `MaxTokens` ×1.5, resend the **same** transcript without consuming the regeneration logic.

3. **Append assistant turn** = `llmResp.ExtractedClass` (feed back the *cleaned* text so error line numbers align with what compiled). **Cycle guard:** if SHA-1 of the class text equals any prior hash → stop, `Verdict=UNSATISFIABLE`, return best-so-far.

4. **Compile** (in-process): `DTL.Util.Compiler.Compile(uniqueClassName, source, .errText)`. Each attempt compiles into a **unique throwaway class** `DTL.Generated.<InputName>_<JobId>_A<n>` (critique 2/3: never reuse the name — a failed recompile must not leave stale `Transform` code that falsely passes). If fail → `Verdict=FAIL_COMPILE`, feedback = verbatim `GetErrorText` (line numbers + offending source line, confirmed gold signal), `Continue`.

5. **Run** (in-process): `DTL.Util.Runner.Run(...)`. If runtime error → `Verdict=FAIL_RUNTIME`, feedback = error text + target DocType, `Continue`.

6. **Verify + score** (in-process): `DTL.Util.Verifier.Score(actualMsg, expectedMsg, ...)` → `score`, `structScore`, `fieldScore`, `Diffs`. Update `BestScore`/`BestClassName`/`BestDTL` if `score > BestScore`.

7. **Apply success policy** (the corrected caveat handling):

   | `SuccessPolicy` | Accept when | Notes |
   |---|---|---|
   | `CompileOnly` | step 4 passed | weakest; "just give me something that compiles" |
   | **`CompileRun` (DEFAULT)** | steps 4+5 passed | **the correct default for non-literal pairs** — objective gates only; score is **reported, not gating** |
   | `CompileMatchTolerance` | 4+5 pass AND `score ≥ MatchThreshold` | opt-in; for pairs the operator trusts as literal |

   This is the key resolution of the three critiques. Critique 1 showed "compile+run" alone is too loose (accepts an empty message) and "exact match" is too strict (caveat); critique 2/3 showed a 0.92 *gating* threshold wastes attempts on legitimately-different pairs. **Resolution:** default `CompileRun` hard-gates on the two objective signals (compiles + runs + produces a structurally non-empty target), always *computes and reports* the tolerant score + diff for human review, but only **escalates HIGH-severity structural diffs** (missing required segments / wrong segment grammar) into regeneration. Value drift on LOW-severity fields (those whose expected value isn't derivable from any source field) never triggers regeneration — that operationalizes the caveat. `CompileMatchTolerance` is the explicit escape hatch when the operator asserts the pair is literal.

8. **Decide:** if policy satisfied → `Success=1`, `Verdict=SUCCESS`, break. Else compute `ScoreDelta`; if `|delta| < 0.01` for `NoImprovementPatience` (default 2) consecutive attempts → stop, `Verdict=UNSATISFIABLE` (the pair is likely non-literal; don't burn the budget — critique 2's plateau exit).

9. **Exit conditions:** `SUCCESS` | `Attempt ≥ MaxAttempts` (return best-so-far, `FAIL_*`) | cycle detected | plateau. Always return the **best compiling+running candidate** with its diff, never a bare failure.

10. **Finalize:** `Compiler.Promote(BestClassName, "DTL.Generated.<InputName>_final")`, delete loser classes (`$system.OBJ.Delete`), copy `BestDTL`/`TransformedHL7`/`DiffSummary` into `ForgeResponse`, write the winning `.cls` + result JSON to `outputs/<InputName>.result/`. The service sends **async** but a response BO / the process's own file-write persists artifacts (critique 1-B3: don't drop the result on the floor).

**Feedback payload per retry** (built by `PromptBuilder.Feedback`):
- *Compile fail:* `"Your class did NOT compile. Return the COMPLETE corrected class (same DocTypes)."` + verbatim line-numbered errors. No diff.
- *Runtime fail:* runtime error + target DocType + "verify every target path exists in the target structure."
- *Match fail (tolerance mode only):* top N (≤25) HIGH/MED diffs as a table `SegName Path | Kind | Expected | Actual | Hint`, current scores, and one summary line for suppressed LOW diffs: `"12 low-confidence field differences suppressed as likely illustrative — do not hard-code these."` (operationalizes the caveat inside the prompt — critique 1-C1).

---

## 4. Dynamic compile + verify (grounded in verified APIs)

**Compile** — `DTL.Util.Compiler.Compile`:
```objectscript
Set io=##class(%Stream.FileCharacter).%New(), io.Filename="/tmp/"_$tr(cls,".","_")_".cls"
Do source.Rewind() While 'source.AtEnd { Do io.Write(source.Read(16000)) }   // full stream, looped
Do io.%Save()
Set sc=$system.OBJ.Load(io.Filename,"ck/displayerror=0",.err)   // ck = compile+keep, suppress console
If $$$ISERR(sc) { Set errText=$system.Status.GetErrorText(sc) Quit 0 }   // line# + offending source line
Quit 1
```
Malformed XData / unterminated `<assign>` yields **ERROR #5559** with the offending line — verified. (A missing repetition index does **not** error — verified; so the prompt must not call it a compile error.)

**Run** — `DTL.Util.Runner.Run`:
```objectscript
Set tMsg=##class(EnsLib.HL7.Message).ImportFromString(crJoined, .sc)   // segments joined by $c(13)
Do:srcDocType'="" tMsg.PokeDocType(srcDocType)
Try { Set sc=$classmethod(cls,"Transform",tMsg,.outMsg) } Catch ex { Set err=ex.DisplayString() Quit 0 }
Quit:$$$ISERR(sc) 0
Set outText=outMsg.OutputToString()   // function form; returns the serialized HL7 string
```

**Normalize + diff** — `DTL.Util.Normalizer` / `DTL.Util.Verifier`, built on the **verified-working** traversal (this is the single biggest correction across all three critiques):

- Iterate segments by ordinal `1..msg.SegCount` (property, not method).
- For each: `seg=msg.GetSegmentAt(i)`, `seg.Name` ("PID"), field count via `seg.GetValueAt("*")`, field/component values via `seg.GetValueAt(field)` / `seg.GetValueAt("5.1.1")`.
- **Never** use named-schema paths through `msg.GetValueAt("PID:5…")` — verified to return empty even on a doctyped message. Use the ordinal `i:field(rep).comp.sub` form (`2:5(1).1.1` → `SMITH`) for any message-level read, or the segment-relative form above.
- `GetNextIndex` is **not** a whole-message leaf iterator — do not use it (critique 2-A1).

Normalization (both sides identically): re-encode to canonical delimiters; neutralize volatile fields to a sentinel (`MSH:7` time, `MSH:10` control ID, `MSH:1/2` encoding chars, `EVN:2`); trim trailing empty components; decode HL7 escapes. Project to `{ordinalPath → value}`.

Scoring: `structScore` = matching segment-name skeleton ratio; `fieldScore` = matching leaf values over **expected-populated paths only** (critical because `create='new'` yields sparse output — verified `MSH|^~\&PID|||||SMITH`, len 23; comparing against a full expected message otherwise floods false `MISSING` diffs — critique 3-C3). `score = 0.5*structScore + 0.5*fieldScore`. Each `VALUE_MISMATCH` whose expected value is not found anywhere in the source projection → `Severity=LOW, Hint="not present in source; likely illustrative"`.

---

## 5. LLM operation + prompt — `DTL.Op.LLMConnector`

`Parameter ADAPTER="EnsLib.HTTP.OutboundAdapter"`. Settings: `Model`, `Mode` (`openai`|`mock`), `ChatPath` (`/v1/chat/completions`), `ApiKeyCredentials` (Ens credentials name — never a logged setting). Adapter settings carry `HTTPServer`/`HTTPPort`/`SSLConfig`: mock = `localhost:8085`, no SSL; OpenAI = `api.openai.com:443` + an `SSLConfig` **that must be created first** (`^SYS Security.SSLConfigs` is empty in this container — verified; document this, the mock is the default).

**Request JSON** (built with `%DynamicObject`, identical for mock and OpenAI):
```json
{ "model":"gpt-4o", "temperature":0, "max_tokens":4096,
  "messages":[ {"role":"system","content":"…"}, {"role":"user","content":"…"}, … ] }
```
Send via the adapter inside the hosted operation. Use `..Adapter.Post(.httpResp, "", httpReq)` with the JSON pre-written to `httpReq.EntityBody` and the path in the adapter `URL` setting — **not** standalone `%New()` (critique 3-A2: `SendFormDataArray` returned `<INVALID OREF>` outside a hosted context; `Post` with empty form-var list sends the EntityBody verbatim). Drop the contradictory `response_format` field (critique 1-A6).

**Response parse** (defensive — critique 1-A7): `Set j={}.%FromJSON(httpResp.Data)` (pass the stream directly, no partial `Read`); guard `HttpStatus`; `Try { Set content=j.choices.%Get(0).message.content }` (0-based) `Catch` → `Ok=0`. Coerce tokens with `+`.

**Extraction** — `DTL.Util.Extractor` (single deterministic path, drop the JSON-mode dual path — critique 3-D1): (1) strip the first ```` ``` ```` fenced block if present (any language tag); (2) slice from first `^\s*Class\s+[%\w.]+\s+Extends` to the final `}`; (3) regex the class name; (4) **validate** it contains `Extends Ens.DataTransformDTL` and `XData DTL`, and that `sourceDocType`/`targetDocType` match the pinned values (critique 3-D6) — else `Ok=0` so the BP issues an "output ONLY the class" corrective turn.

**Prompt strategy** (`PromptBuilder`): static system prompt = the verified DTL skeleton (`Extends Ens.DataTransformDTL [ DependsOn = EnsLib.HL7.Message ]`, `XData DTL [ XMLNamespace="http://www.intersystems.com/dtl" ]`, `<transform … create='new' language='objectscript'>`, `<assign value='source.{SEG:f(rep).c.s}' property='target.{…}' action='set'/>`), the `{SEG:field(rep).comp.sub}` brace grammar, allowed elements, and DocType pinning. **Correction vs. critiques:** do NOT state "missing repetition index = compile error" (verified false); describe it as a *semantic* default-to-rep-1. Initial user prompt: pinned `SourceDocType`/`TargetDocType` (derived from MSH-9 type^trigger + MSH-12 version → `"2.5:ADT_A01"`, verified readable), the raw pair, optional operator Instructions, and the explicit caveat ("the pair illustrates the KIND of mapping; infer general rules; do not hard-code instance-specific values").

**Mock** (`mock/mock_llm.py`, `http.server`, binds `0.0.0.0:8085`, no deps): counts `assistant` turns in the request to script a curriculum: 0 prior → return a **genuinely non-compiling** DTL (malformed/unterminated `<assign>` — verified to raise #5559; NOT a missing index); 1 prior → a DTL that compiles but mis-maps one field (exercises the diff branch in tolerance mode); 2+ prior → the correct, compiling, verifying DTL. Emits the exact OpenAI envelope (`choices[0].message.content`, `finish_reason`, `usage`). Scripted payloads live in `mock/scenarios/*.cls` so they're editable without touching server code, and are pre-baked to `2.5:ADT_A01` so the "correct" one actually verifies in the container.

---

## 6. Example message pairs (author these)

Same basename in `inputs/` and `outputs/`. Each illustrates a distinct interface idiom; outputs are illustrative (caveat-honoring).

1. **`adt_a01_name_normalize`** — ADT^A01 → ADT^A01. Copy MSH/PID/PV1 through; uppercase PID-5.1 family name; restamp MSH-7 with current time and MSH-10 with a new control ID (the volatile fields the normalizer neutralizes — demonstrates normalization).
2. **`adt_a08_id_select`** — ADT^A08 → ADT^A08. PID-3 is a repeating identifier list; select a specific repetition (`PID:3(2)`) into the target's primary ID — demonstrates the repetition-index grammar.
3. **`oru_r01_units_remap`** — ORU^R01 → ORU^R01. OBX-5 value passthrough with OBX-6 units **code** swap (e.g. `mg/dL`→`mmol/L` as a literal code map, no arithmetic) — demonstrates coded-field mapping and a multi-segment (OBX repeating) structure.
4. **`adt_a01_facility_remap`** — ADT^A01 → ADT^A01. Remap MSH-4/MSH-6 sending/receiving facility via literal lookup; trigger-event change ADT^A01→ADT^A08 in MSH-9 — demonstrates header rewrites and a non-literal pair (good test for `CompileRun` default + reported-but-not-gating score).

---

## 7. Build order & risks

**Build order:**
1. `DTL.Msg.*` (ChatTurn, FieldDiff serial; ForgeRequest/Response, LLMRequest/Response) — compile-check first, everything depends on them.
2. `DTL.Util.HL7` + `DTL.Util.Normalizer` + `DTL.Util.Verifier` — and immediately unit-test the ordinal-path traversal against a real message in the container (the highest-risk code).
3. `DTL.Util.Compiler` + `DTL.Util.Runner` — test compile-error capture and a known-good transform end-to-end.
4. `DTL.Util.Extractor` + `DTL.Util.PromptBuilder`.
5. `mock/mock_llm.py` + `mock/scenarios/*.cls` — verify the broken scenario actually fails compile and the correct one verifies.
6. `DTL.Op.LLMConnector` — test against the running mock **inside a started production** (not standalone).
7. `DTL.Proc.Orchestrator` (the loop), then `DTL.Svc.PairFileService`, then `DTL.Setup.Production` + `DTL.Setup.Installer`.
8. Author the 4 example pairs; full E2E: drop a pair, confirm `AttemptsUsed=2..3`, `Success=1`, artifacts written.

**Top 3 risks:**
1. **HL7 path resolution.** Named-schema paths (`PID:5…`) return empty through `msg.GetValueAt`; only ordinal (`2:5`) or segment-relative (`GetSegmentAt(i).GetValueAt(5)`) work. The verifier is worthless if this is wrong — build and test it against the live container *first*. (This sank the diff routines in proposals 1 and 2.)
2. **Compile isolation / namespace hygiene.** Loading LLM-authored ObjectScript into the live namespace is a code-injection surface and an accumulation hazard. Use a unique throwaway class per attempt, `$system.OBJ.Delete` losers, promote only the winner. A failed recompile must never leave stale `Transform` code that falsely "passes."
3. **The caveat / success policy.** Default to `CompileRun` (objective gates) with score reported-but-not-gating; reserve `CompileMatchTolerance` as opt-in. Getting this wrong in either direction (accept-garbage vs. infinite-regenerate on a non-literal pair) is the difference between a useful tool and one that burns the attempt budget every run. The plateau/cycle guards are the backstop.