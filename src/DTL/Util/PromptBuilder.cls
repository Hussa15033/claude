/// Builds the system / initial-user / feedback-user prompts that steer the LLM
/// toward a compilable, verifying InterSystems DTL class. All knowledge that was
/// proven in the live container (DTL skeleton, brace path grammar, DocType=
/// structure, repetition indexes, grouped segments) is encoded here.
Class DTL.Util.PromptBuilder Extends %RegisteredObject
{

/// Static system prompt: teaches the model exactly the DTL shape that compiles.
ClassMethod SystemPrompt() As %String
{
	set nl = $char(10)
	set p = "You are an expert InterSystems IRIS interoperability engineer. You write InterSystems Data Transformation Language (DTL) classes that transform HL7 v2 messages." _ nl _ nl
	set p = p _ "Output rules:" _ nl
	set p = p _ "- Output ONLY a single complete ObjectScript class definition. No prose, no explanation." _ nl
	set p = p _ "- You MAY wrap it in a ```objectscript code fence, but nothing else." _ nl _ nl
	set p = p _ "The class MUST follow exactly this shape:" _ nl
	set p = p _ "Class <PackageName> Extends Ens.DataTransformDTL [ DependsOn = EnsLib.HL7.Message ]" _ nl
	set p = p _ "{" _ nl
	set p = p _ "XData DTL [ XMLNamespace = ""http://www.intersystems.com/dtl"" ]" _ nl
	set p = p _ "{" _ nl
	set p = p _ "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' sourceDocType='<SRC>' targetDocType='<TGT>' create='copy' language='objectscript'>" _ nl
	set p = p _ "  <assign value='source.{MSH:3.1}' property='target.{MSH:3.1}' action='set'/>" _ nl
	set p = p _ "</transform>" _ nl
	set p = p _ "}" _ nl
	set p = p _ "}" _ nl _ nl
	set p = p _ "DTL path grammar (HL7 segment fields):" _ nl
	set p = p _ "- {SEG:field.component.subcomponent}, e.g. {PID:5.1.1}." _ nl
	set p = p _ "- Repeating fields REQUIRE a repetition index in parentheses: {PID:5(1).1.1} for the first repetition." _ nl
	set p = p _ "- Segments inside HL7 groups need the group prefix. In ORU_R01, PID is reached as {PIDgrpgrp(1).PIDgrp.PID:3(1).4}. ADT messages have PID/PV1 at the top level: {PID:...}, {PV1:...}." _ nl
	set p = p _ "- MSH-1 is the field separator and MSH-2 the encoding chars; do not overwrite them. The HL7 version lives in MSH-12 ({MSH:12})." _ nl _ nl
	set p = p _ "Use create='copy' to pass the whole message through, then <assign> only the fields that change. Use create='new' only when the target is built from scratch." _ nl
	set p = p _ "The sourceDocType/targetDocType are the message STRUCTURE 'version:structure' (e.g. 2.3:ADT_A01). Note an HL7 2.3 ADT^A08 uses the ADT_A01 structure. Use exactly the DocTypes given to you." _ nl _ nl
	set p = p _ ..DtlSchema() _ nl
	set p = p _ ..XmlEscapingRule()
	quit p
}

/// The COMPLETE, TESTED DTL element/attribute reference (every element + form
/// below was compiled live on IRIS for Health). The model must use ONLY these
/// elements and attributes — anything else produces "Invalid DTL". Kept concise.
ClassMethod DtlSchema() As %String
{
	set nl = $char(10)
	set p = "DTL XML SCHEMA — use ONLY these elements/attributes (exactly as written; any other element or attribute is INVALID):" _ nl
	// transform (root)
	set p = p _ "<transform> (root, exactly one): required attrs sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' sourceDocType='ver:struct' targetDocType='ver:struct' create='copy|new|existing' language='objectscript'. Contains a flat, ORDERED list of the action elements below." _ nl
	// assign
	set p = p _ "<assign value='EXPR' property='target.{PATH}' action='set|append|clear|insert|remove' [key='EXPR']/>  — the workhorse. value is an ObjectScript expression (a literal string is &quot;TEXT&quot;); property is the target path. action='set' overwrites; 'append' adds a repetition; 'clear' empties; 'insert'/'remove' need key=. Self-closing." _ nl
	// if
	set p = p _ "<if condition='OBJECTSCRIPT-BOOLEAN'><true> …actions… </true><false> …actions… </false></if>  — <false> is optional. condition is an ObjectScript boolean expression." _ nl
	// switch
	set p = p _ "<switch><case condition='BOOL'> …actions… </case><default> …actions… </default></switch>  — zero or more <case>, optional single <default>." _ nl
	// foreach
	set p = p _ "<foreach property='source.{REPEATING-PATH}' key='k'> …actions… </foreach>  — iterates a repeating field/segment; use the loop var (e.g. k) as the repetition index inside, e.g. target.{PID:3(k).1}. The path's repeating node ends in () e.g. {PID:3()} or a repeating group {PIDgrpgrp()}." _ nl
	// code
	set p = p _ "<code><![CDATA[ <one or more lines of valid ObjectScript> ]]></code>  — raw ObjectScript escape hatch; source/target are in scope. Must be valid ObjectScript." _ nl
	// trace / comment
	set p = p _ "<trace value='EXPR'/>  — emit a trace message (self-closing)." _ nl
	set p = p _ "<comment/>  — MUST be empty/self-closing; it takes NO text content (text inside <comment> is INVALID)." _ nl _ nl
	set p = p _ "Do NOT invent attributes (no id=, name=, desc= on these elements). Every element above is self-closing OR properly paired; never leave a tag unclosed." _ nl
	quit p
}

/// The CRITICAL rule (its own reusable block, also injected into repair prompts):
/// every XML attribute value is single-quoted, so ANY special XML character that
/// appears INSIDE value='...' / condition='...' MUST be written as an XML entity,
/// NOT as the literal character — otherwise the attribute terminates early and the
/// DTL fails to parse/compile. This is the #1 cause of generated-DTL compile
/// failures because ObjectScript's not-equal operator is an apostrophe ('=).
ClassMethod XmlEscapingRule() As %String
{
	set nl = $char(10)
	set p = "CRITICAL — XML ENTITY ESCAPING INSIDE ATTRIBUTE VALUES:" _ nl
	set p = p _ "All DTL attributes (value='...', condition='...', property='...') are wrapped in SINGLE QUOTES. Any of these characters appearing INSIDE an attribute value MUST be written as its XML entity, never the literal character:" _ nl
	set p = p _ "  '  (apostrophe / ObjectScript NOT)  ->  &apos;" _ nl
	set p = p _ "  """ _ " (double quote)                  ->  &quot;" _ nl
	set p = p _ "  &  (ampersand)                      ->  &amp;" _ nl
	set p = p _ "  <  (less-than)                       ->  &lt;" _ nl
	set p = p _ "  >  (greater-than)                    ->  &gt;" _ nl
	set p = p _ "This matters most for ObjectScript operators inside condition=/value=: the not-equal operator '= and not-less '< etc. use an apostrophe." _ nl
	set p = p _ "  INVALID:  <if condition='source.{PID:8}'=""F""'>           (the bare ' and "" break the attribute)" _ nl
	set p = p _ "  VALID:    <if condition='source.{PID:8}&apos;=&quot;F&quot;'>" _ nl
	set p = p _ "  INVALID:  <assign value='""A""&""B""' .../>               (bare & and "")" _ nl
	set p = p _ "  VALID:    <assign value='&quot;A&quot;&amp;&quot;B&quot;' .../>" _ nl
	set p = p _ "A literal string constant in a value still needs its surrounding double-quotes escaped, e.g. set MSH-3 to EPIC = value='&quot;EPIC&quot;'." _ nl
	quit p
}

/// STEP 0 — SPEC STRUCTURING. Turn the RAW extracted spec (which may be noisy:
/// PDF table artefacts, headers/footers, multi-column bleed) into an explicit,
/// numbered, unambiguous list of transformation RULES for a human to verify BEFORE
/// any DTL work. Crucially we also ask for PROVENANCE: for each rule, the verbatim
/// snippet of the ORIGINAL spec it came from — so the review UI can show which part
/// of the source produced each rule and flag rules with no source (hallucinations).
/// The model returns STRICT JSON so we can render the side-by-side review reliably.
ClassMethod SpecStructurePrompt(pRawSpec As %String, pSrcDocType As %String, pInputsBlock As %String = "") As %String
{
	set nl = $char(10)
	set p = "You are normalising a clinical interface SPECIFICATION into an explicit, reviewable rule list. The raw text was extracted from an uploaded document (PDF/Word) and MAY contain extraction noise (page headers/footers, broken tables, column bleed, hyphenation). Do NOT invent requirements: every rule must be traceable to the source text." _ nl _ nl
	set p = p _ "Source message DocType (the HL7 structure the rules act on): " _ pSrcDocType _ nl _ nl
	set p = p _ "Produce STRICT JSON ONLY (no prose, no code fence), matching exactly:" _ nl
	set p = p _ "{" _ nl
	set p = p _ "  ""title"": ""<short title of this interface spec>""," _ nl
	set p = p _ "  ""rules"": [" _ nl
	set p = p _ "    {""index"": 1, ""rule"": ""<one concrete, testable transformation rule, segment/field level where possible>"", ""sourceQuote"": ""<verbatim snippet from the spec this rule came from, or empty string if you inferred it>"", ""inferred"": false}" _ nl
	set p = p _ "  ]," _ nl
	set p = p _ "  ""ambiguities"": [""<anything in the spec that is unclear/contradictory/missing and needs a human decision>""]" _ nl
	set p = p _ "}" _ nl _ nl
	set p = p _ "Rules:" _ nl
	set p = p _ "- One transformation per rule; keep them concrete (""Set MSH-4 to 001"", ""Map PID-8 F->2""), not vague (""clean up the message"")." _ nl
	set p = p _ "- sourceQuote MUST be copied verbatim from the SPECIFICATION below (a short phrase is fine). If a rule is your inference from the example input rather than stated in the spec, set inferred=true and sourceQuote=""""." _ nl
	set p = p _ "- List genuine ambiguities/gaps so the reviewer can resolve them now rather than after a wrong DTL is built." _ nl
	set p = p _ "- Output ONLY the JSON object." _ nl _ nl
	set p = p _ "SPECIFICATION (raw extracted text):" _ nl _ pRawSpec _ nl _ nl
	if pInputsBlock '= "" set p = p _ "Example INPUT message(s) for context (use only to disambiguate the spec, not as a source of new rules unless clearly implied):" _ nl _ pInputsBlock _ nl
	quit p
}

/// CONCISE SPEC generation (run once at upload). Turn the raw extracted spec into a
/// clear, de-noised specification GROUPED BY MESSAGE / SEGMENT TYPE, every item
/// carrying a verbatim reference back to the original so the side-by-side review can
/// link each concise item to its source. STRICT JSON so the UI can render groups +
/// click-to-reference reliably.
ClassMethod ConciseSpecPrompt(pRawSpec As %String) As %String
{
	set nl = $char(10)
	set p = "You are turning a raw, noisy interface SPECIFICATION (extracted from a PDF/Word document — it may contain page headers/footers, broken tables, column bleed, hyphenation) into a CLEAR, CONCISE, organised specification for an HL7 v2 integration engineer to review." _ nl _ nl
	set p = p _ "Organise the transformation requirements GROUPED BY the HL7 message type and segment they apply to (e.g. a group for ADT^A01 / MSH, one for PID, etc.; use a 'General' group for cross-message rules). Be concise: one concrete, testable requirement per item; drop prose, boilerplate, and document chrome." _ nl _ nl
	set p = p _ "Do NOT invent requirements. Every item MUST be traceable to the source text via a verbatim quote. If you must infer something to make a rule actionable, mark inferred=true and leave sourceQuote empty." _ nl _ nl
	set p = p _ "Produce STRICT JSON ONLY (no prose, no code fence), matching exactly:" _ nl
	set p = p _ "{" _ nl
	set p = p _ "  ""title"": ""<short title of this interface>""," _ nl
	set p = p _ "  ""groups"": [" _ nl
	set p = p _ "    {""type"": ""<message/segment this group is about, e.g. 'MSH' or 'PID' or 'General'>""," _ nl
	set p = p _ "     ""items"": [ {""id"": ""g1i1"", ""rule"": ""<one concrete requirement>"", ""appliesTo"": [""*""], ""sourceQuote"": ""<verbatim snippet from the spec, or empty if inferred>"", ""inferred"": false} ] }" _ nl
	set p = p _ "  ]," _ nl
	set p = p _ "  ""ambiguities"": [ {""question"": ""<an unclear/contradictory/missing thing that needs a human decision>"", ""segment"": ""<the EXACT group `type` from groups[] that this question relates to, e.g. 'PID' or 'MSH'>"", ""options"": [""<one concrete, actionable way to resolve it>"", ""<a different concrete option>""]} ]" _ nl
	set p = p _ "}" _ nl _ nl
	set p = p _ "Give every item a UNIQUE id (groupindex+itemindex, e.g. g2i3). sourceQuote must be copied verbatim from the SPECIFICATION below so the reviewer can locate it." _ nl _ nl
	set p = p _ "CRITICAL — MESSAGE-TYPE SCOPING via the ""appliesTo"" field on EVERY item:" _ nl
	set p = p _ "- ""appliesTo"" lists the HL7 message type(s) the rule governs, as an array of structure names like ""ADT^A01"", ""ORU^R01"", ""REF^I12"", ""SIU^S12"", ""ACK""." _ nl
	set p = p _ "- A rule that comes from a GENERIC/SHARED segment definition (e.g. a generic MSH, PID, OBR, OBX section that is NOT under a specific message type, and therefore applies to ALL messages) MUST use appliesTo=[""*""] (the wildcard meaning 'all message types'). Most segment-field-format rules are generic — default to [""*""] unless the spec explicitly restricts the rule to particular message type(s)." _ nl
	set p = p _ "- Only list specific message types in appliesTo when the spec EXPLICITLY scopes the rule to them (e.g. a rule that only applies 'in a Discharge Summary' or 'for ACK messages'). Do NOT guess a single message type just because a rule sits near one example — when in doubt, use [""*""]." _ nl
	set p = p _ "- This matters because a downstream DTL is built for ONE message type at a time: a generic rule wrongly scoped to one message type would be silently dropped for all others. Erring toward [""*""] is safe; wrongly narrowing is not." _ nl
	set p = p _ "For EVERY ambiguity, supply 2-4 concrete, mutually-exclusive resolution OPTIONS the reviewer can choose from (each option a short, actionable decision, e.g. ""Map F to 2 and M to 1"" or ""Leave PID-8 unchanged""), AND set ""segment"" to the EXACT `type` string of the group in groups[] the question belongs to (so the resolved decision can be filed with that segment). The reviewer may also type a custom answer, so the options need not be exhaustive — but make them specific, not vague. If there are genuinely no ambiguities, return an empty array." _ nl
	set p = p _ "Output ONLY the JSON object." _ nl _ nl
	set p = p _ "SPECIFICATION (raw extracted text):" _ nl _ pRawSpec _ nl
	quit p
}

/// VERIFY the concise spec against the original — completeness + no hallucination.
/// A second LLM pass (the human verifies too, in the UI) that flags requirements in
/// the original that the concise spec MISSED, and items in the concise spec that are
/// NOT supported by the original (hallucinations). STRICT JSON.
ClassMethod ConciseVerifyPrompt(pRawSpec As %String, pConcise As %String) As %String
{
	set nl = $char(10)
	set p = "You are auditing a CONCISE specification against the ORIGINAL it was derived from. Find (a) requirements stated in the ORIGINAL that are MISSING from the concise version, and (b) items in the CONCISE version that are NOT supported by the original (hallucinations / overreach)." _ nl _ nl
	set p = p _ "Return STRICT JSON ONLY:" _ nl
	set p = p _ "{""complete"": true|false, ""faithful"": true|false, ""score"": 0.0-1.0, ""missing"": [""<requirement in the original not captured>""], ""hallucinated"": [""<concise item with no basis in the original>""], ""notes"": ""<one line>""}" _ nl _ nl
	set p = p _ "complete=true only if no material requirement is missing; faithful=true only if nothing is hallucinated. score = fraction of original requirements correctly and faithfully captured. Be strict but do not penalise pure reorganisation/concision." _ nl _ nl
	set p = p _ "ORIGINAL SPECIFICATION:" _ nl _ pRawSpec _ nl _ nl
	set p = p _ "CONCISE SPECIFICATION:" _ nl _ pConcise _ nl
	quit p
}

/// The BUILD system prompt: the static, CACHEABLE prefix sent on every plan /
/// generation / repair call. It bundles everything that does NOT change across the
/// build conversation — the DTL authoring rules, the element schema, the XML
/// escaping rule, the HL7 schema for the DocType(s), and the APPROVED STRUCTURED
/// SPEC (the authority for what the DTL must do). Because it is stable and marked
/// as the cache breakpoint, the provider re-reads it from prompt cache on every
/// subsequent turn instead of re-billing it at full input price.
ClassMethod BuildSystemPrompt(pStructuredSpec As %String, pSrcDocType As %String, pTgtDocType As %String = "") As %String
{
	set nl = $char(10)
	set p = ..SystemPrompt() _ nl
	set tSchema = ..SchemaBlock(pSrcDocType, pTgtDocType)
	if tSchema '= "" {
		set p = p _ "----- HL7 MESSAGE SCHEMA (authoritative paths/fields) -----" _ nl _ tSchema _ nl
		set p = p _ "Every source.{...} and target.{...} path you write MUST be one of the paths above (full group prefix; a repetition index on any () node)." _ nl _ nl
	}
	set p = p _ "----- APPROVED TRANSFORMATION SPECIFICATION (the AUTHORITY for what to implement) -----" _ nl
	set p = p _ "A human has reviewed and APPROVED the following structured specification. Implement EVERY rule in it. Do not contradict it and do not silently drop rules. The example input message is for testing only — the SPEC, not the input, defines correct behaviour." _ nl _ nl
	set p = p _ pStructuredSpec _ nl
	quit p
}

/// LLM-as-JUDGE conformance prompt. After a candidate DTL compiles and runs on an
/// input, ask a fresh-perspective grader whether the PRODUCED OUTPUT actually
/// satisfies the approved spec — this catches the silent-wrong-output case a
/// compile+run gate cannot (a bad path that the DTL try/catch swallows leaves the
/// field simply unchanged, no error). Returns STRICT JSON the gate can act on.
///
/// SCOPING (critical): a spec typically covers MANY message types (ADT, ORU, REF,
/// SIU, ACK…). This candidate is ONE transform for ONE message type (pDocType). The
/// judge MUST grade ONLY the rules that apply to THIS message type — a rule written
/// for a different message type, or a conditional rule whose trigger value is not
/// present in THIS input, is NOT a violation. Without this, dozens of inapplicable
/// rules pin the score below 1.0 and a single inapplicable "violation" blocks pass.
ClassMethod JudgePrompt(pStructuredSpec As %String, pInput As %String, pOutput As %String, pDocType As %String = "") As %String
{
	set nl = $char(10)
	set tType = $piece(pDocType, ":", 2)   // "2.4:ORU_R01" -> "ORU_R01"
	if tType = "" set tType = pDocType
	set p = "You are a strict, FAIR QA reviewer for an HL7 v2 transformation. Decide whether the PRODUCED OUTPUT correctly implements the APPROVED SPECIFICATION for the given INPUT. Ignore volatile fields (message timestamp MSH-7, control id MSH-10)." _ nl _ nl
	if tType '= "" {
		set p = p _ "MESSAGE TYPE UNDER TEST: " _ tType _ ". This DTL transforms ONLY this message type." _ nl
	}
	set p = p _ "SCOPING RULES — apply these BEFORE deciding anything:" _ nl
	set p = p _ "1. Grade ONLY spec rules that apply to this message" _ $select(tType'="":" (" _ tType _ ")", 1:"") _ ". A rule that targets a DIFFERENT message type (e.g. a rule about an ADT/SIU/REF/ACK message when this is something else) is OUT OF SCOPE — do NOT list it and do NOT let it lower the score." _ nl
	set p = p _ "2. A CONDITIONAL rule (one scoped to a particular scenario or triggered only when a field has a particular value, e.g. 'when field X is present…' or 'for <a specific event/message variant>…') is in scope ONLY if its condition is actually TRUE for THIS input. If the triggering value/scenario is not present in this input, the rule does not apply — do NOT count it." _ nl
	set p = p _ "3. A field the spec only requires to be CARRIED THROUGH (passed unchanged) is satisfied as long as the output preserves the input value; a copy-through transform satisfies it automatically." _ nl _ nl
	set p = p _ "Return STRICT JSON ONLY:" _ nl
	set p = p _ "{""conforms"": true|false, ""score"": 0.0-1.0, ""violations"": [{""rule"": ""<the IN-SCOPE spec rule that is NOT satisfied>"", ""detail"": ""<what the output shows vs what the spec requires>"", ""severity"": ""HIGH|LOW""}], ""notes"": ""<one line>""}" _ nl _ nl
	set p = p _ "CRITICAL — what counts as a violation:" _ nl
	set p = p _ "- ONLY list a rule in ""violations"" if the output genuinely FAILS that in-scope rule. NEVER list a rule that is satisfied. If your detail would say 'this is satisfied' / 'no violation here' / 'correct', then DO NOT include that entry at all." _ nl
	set p = p _ "- Use severity HIGH for a real correctness defect (wrong/missing value the spec mandates for this message). Use severity LOW for a minor/cosmetic shortfall that does not make the message incorrect." _ nl
	set p = p _ "- conforms=true when there are NO HIGH-severity violations (LOW-only or empty is still conforming). violations may still list LOW items for the reviewer's information." _ nl
	set p = p _ "- score = fraction of IN-SCOPE rules correctly applied (ignore out-of-scope/inapplicable rules entirely in this fraction)." _ nl _ nl
	set p = p _ "APPROVED SPECIFICATION (covers multiple message types — apply the scoping rules above):" _ nl _ pStructuredSpec _ nl _ nl
	set p = p _ "INPUT MESSAGE" _ $select(tType'="":" (" _ tType _ ")", 1:"") _ ":" _ nl _ ..PrettyHL7(pInput) _ nl _ nl
	set p = p _ "PRODUCED OUTPUT:" _ nl _ ..PrettyHL7(pOutput) _ nl
	quit p
}

/// SPEC-DRIVEN planning prompt: the transformation is described by the spec only;
/// there are NO expected output messages — only example INPUT messages. Ask the
/// model for a short plan of the changes it will implement.
ClassMethod SpecPlanPrompt(pSpec As %String, pSrcDocType As %String, pInputsBlock As %String = "") As %String
{
	set nl = $char(10)
	set p = "Before writing any DTL, produce a SHORT PLAN of the transformation you intend to implement, for a human to review and approve." _ nl
	set p = p _ "The transformation is defined ENTIRELY by the specification below. There are NO example output messages — infer the output purely from the spec." _ nl
	set p = p _ "Source DocType (primary input): " _ pSrcDocType _ nl _ nl
	set tSchema = ..SchemaBlock(pSrcDocType)
	if tSchema '= "" set p = p _ tSchema _ nl
	set p = p _ "SPECIFICATION:" _ nl _ pSpec _ nl _ nl
	if pInputsBlock '= "" {
		set p = p _ "Example INPUT messages this DTL must handle:" _ nl _ pInputsBlock _ nl _ nl
	}
	set p = p _ "The specification is AUTHORITATIVE: every rule it states must appear in your plan, and you must NOT contradict it." _ nl
	set p = p _ "You MAY additionally propose sensible extra transformation steps that you infer from the example INPUT message(s) — e.g. obvious normalisations, derived/version fields, or cleanups the spec did not mention — PROVIDED they do not conflict with anything in the specification. Mark any such inferred items by appending ' (suggested)' so the reviewer can tell them apart from spec-mandated changes." _ nl
	set p = p _ "Output ONLY a numbered markdown list of the concrete changes the DTL will make (segment/field level). No DTL code yet. Keep it under 15 bullets." _ nl
	quit p
}

/// Extra plan items the REVIEWER added before approving. They are additional
/// REQUIRED transformation steps; they augment (never replace) the plan and the
/// specification.
ClassMethod PlanAdditionsPrompt(pAdditions As %String) As %String
{
	set nl = $char(10)
	set p = "The reviewer APPROVED the plan and ADDED the following extra transformation steps. Treat each as a REQUIRED part of the plan and implement it in the DTL, in addition to everything already in the plan and specification (do not drop or contradict the existing items):" _ nl
	set p = p _ pAdditions _ nl
	quit p
}

/// SPEC-DRIVEN initial generation prompt (no expected output to match against).
ClassMethod SpecInitialPrompt(pSpec As %String, pSrcDocType As %String, pTgtDocType As %String, pPrimaryInput As %String, pClassName As %String) As %String
{
	set nl = $char(10)
	set p = "Write a DTL class named '" _ pClassName _ "' that implements the transformation described in the specification." _ nl
	set p = p _ "Pin sourceDocType='" _ pSrcDocType _ "' and targetDocType='" _ pTgtDocType _ "'." _ nl _ nl
	set p = p _ "There are NO example output messages. Implement the rules from the spec/plan above. The DTL must COMPILE and RUN without error on the example input." _ nl _ nl
	set tSchema = ..SchemaBlock(pSrcDocType, pTgtDocType)
	if tSchema '= "" set p = p _ tSchema _ "Every source.{...} and target.{...} path you write MUST be one of the paths above (with the full group prefix and a repetition index on any () node)." _ nl _ nl
	set p = p _ "SPECIFICATION:" _ nl _ pSpec _ nl _ nl
	set p = p _ "Example INPUT (" _ pSrcDocType _ ") the DTL will be run against:" _ nl _ ..PrettyHL7(pPrimaryInput) _ nl
	quit p
}

/// Feedback when the user CORRECTS a transformed output (live test or review):
/// they edited the produced message and/or gave text feedback. Teach the DTL to
/// produce the corrected output for that input.
ClassMethod CorrectionPrompt(pInput As %String, pProduced As %String, pCorrected As %String, pFeedback As %String) As %String
{
	set nl = $char(10)
	set p = "A reviewer ran your DTL and corrected its output. Update the COMPLETE DTL class (same class name + DocTypes) so it produces the corrected output for this input, and generalise the rule where sensible." _ nl _ nl
	set p = p _ "INPUT:" _ nl _ ..PrettyHL7(pInput) _ nl _ nl
	if pProduced '= "" set p = p _ "YOUR DTL PRODUCED:" _ nl _ ..PrettyHL7(pProduced) _ nl _ nl
	if pCorrected '= "" set p = p _ "CORRECTED OUTPUT (what it SHOULD produce):" _ nl _ ..PrettyHL7(pCorrected) _ nl _ nl
	if pFeedback '= "" set p = p _ "REVIEWER FEEDBACK:" _ nl _ pFeedback _ nl _ nl
	set p = p _ "Return the COMPLETE corrected DTL class." _ nl
	quit p
}

/// Planning prompt: ask the model to lay out the transformation plan (in plain
/// language) BEFORE writing any DTL, so the user can review/approve it. Returns a
/// concise, numbered markdown plan of the field-level changes it intends to make.
ClassMethod PlanPrompt(pSourceHL7 As %String, pTargetHL7 As %String, pSrcDocType As %String, pTgtDocType As %String, pInstructions As %String = "") As %String
{
	set nl = $char(10)
	set p = "Before writing any DTL, produce a SHORT PLAN of the transformation you intend to implement, for a human to review and approve." _ nl
	set p = p _ "Source DocType: " _ pSrcDocType _ "   Target DocType: " _ pTgtDocType _ nl _ nl
	if pInstructions '= "" {
		set p = p _ "Specification / operator intent:" _ nl _ pInstructions _ nl _ nl
	}
	set p = p _ "EXAMPLE INPUT:" _ nl _ ..PrettyHL7(pSourceHL7) _ nl _ nl
	set p = p _ "EXAMPLE OUTPUT:" _ nl _ ..PrettyHL7(pTargetHL7) _ nl _ nl
	set p = p _ "Output ONLY a numbered markdown list of the concrete changes (e.g. 'Set MSH-3 to EPIC', 'Map PID-8 F->2', 'Bump version 2.3->2.5'). Do NOT write any DTL or code yet. Keep it under 12 bullet points." _ nl
	quit p
}

/// Feedback prompt when the user REJECTS an attempt with free-text guidance.
ClassMethod RejectionPrompt(pFeedback As %String) As %String
{
	set nl = $char(10)
	set p = "The reviewer REJECTED your previous DTL with this feedback:" _ nl
	set p = p _ pFeedback _ nl _ nl
	set p = p _ "Return the COMPLETE corrected DTL class (same class name and DocTypes) addressing this feedback." _ nl
	quit p
}

/// Initial user prompt for attempt 1.
ClassMethod InitialUserPrompt(pSourceHL7 As %String, pTargetHL7 As %String, pSrcDocType As %String, pTgtDocType As %String, pInstructions As %String = "", pClassName As %String = "DTL.Generated.Candidate") As %String
{
	set nl = $char(10)
	set p = "Write a DTL class named '" _ pClassName _ "' that transforms the EXAMPLE INPUT below into the style of the EXAMPLE OUTPUT." _ nl
	set p = p _ "Pin sourceDocType='" _ pSrcDocType _ "' and targetDocType='" _ pTgtDocType _ "'." _ nl _ nl
	if pInstructions '= "" {
		set p = p _ "Transformation intent (operator notes):" _ nl _ pInstructions _ nl _ nl
	}
	set p = p _ "IMPORTANT: the example pair illustrates the KIND of transformation expected. The example output is NOT guaranteed to be the literal machine transform of the example input. Infer the GENERAL mapping rules (field remaps, code maps, version bump, header rewrites). Do not hard-code values that are specific to this one instance and not derivable from the input." _ nl _ nl
	set tSchema = ..SchemaBlock(pSrcDocType, pTgtDocType)
	if tSchema '= "" set p = p _ tSchema _ "Every source.{...} and target.{...} path you write MUST be one of the paths above." _ nl _ nl
	set p = p _ "EXAMPLE INPUT (" _ pSrcDocType _ "):" _ nl _ ..PrettyHL7(pSourceHL7) _ nl _ nl
	set p = p _ "EXAMPLE OUTPUT (" _ pTgtDocType _ "):" _ nl _ ..PrettyHL7(pTargetHL7) _ nl
	quit p
}

/// Feedback user prompt for attempt k>1, given the prior attempt's result object.
ClassMethod FeedbackPrompt(pResult As %DynamicObject, pTgtDocType As %String) As %String
{
	set nl = $char(10)
	// Compile failure: give verbatim errors, no diff.
	if 'pResult.compiled {
		set p = "Your class did NOT compile. Return the COMPLETE corrected class (same class name and DocTypes). Fix these compiler errors:" _ nl
		set p = p _ pResult.compileErrors _ nl
		quit p
	}
	// Runtime failure.
	if 'pResult.ran {
		set p = "Your class compiled but FAILED at runtime. Make sure every target path exists in target DocType '" _ pTgtDocType _ "' and every source path is valid. Error:" _ nl
		set p = p _ $get(pResult.runErrors) _ nl
		set p = p _ "Return the COMPLETE corrected class." _ nl
		quit p
	}
	// Match failure: show the diff (HIGH/MED first), note suppressed LOW diffs.
	set p = "Your class compiled and ran, but the output does not yet match the expected output." _ nl
	set p = p _ "Field differences (expected vs actual):" _ nl
	set p = p _ ##class(DTL.Util.Verifier).DiffsToText(pResult.diffs, 25)
	set p = p _ "Adjust the <assign> statements so the actual output matches the expected output for the HIGH-severity differences. LOW-severity differences whose expected value is not present in the source are likely illustrative — do NOT hard-code them." _ nl
	set p = p _ "Return the COMPLETE corrected class." _ nl
	quit p
}

/// Auto-repair prompt fed back to the LLM when a generated DTL fails to COMPILE.
/// LEAN: the full DTL element schema + XML-escaping rule + HL7 schema already live
/// in the (prompt-cached) BUILD SYSTEM PROMPT, so we do NOT re-inject them here —
/// re-sending ~3-50 KB of identical reference on every repair round is pure token
/// waste. We send only the DELTA the model needs: the verbatim errors + a short
/// pointed reminder. (The DocTypes are restated because they're short and the
/// single most common drift.)
ClassMethod CompileFixPrompt(pErrors As %String, pSrcDocType As %String, pTgtDocType As %String) As %String
{
	set nl = $char(10)
	set p = "Your DTL did NOT COMPILE. Below are the verbatim InterSystems ObjectScript compiler errors (with line numbers and the offending generated line). Fix EVERY error and return the COMPLETE corrected class — same class name, sourceDocType='" _ pSrcDocType _ "', targetDocType='" _ pTgtDocType _ "'." _ nl _ nl
	set p = p _ "COMPILER ERRORS:" _ nl _ pErrors _ nl _ nl
	set p = p _ "Reminder (full DTL element + XML-escaping rules are in the system prompt above): a parse/SAX error, an unexpected ' or "" , or a truncated attribute is almost always an UNESCAPED character inside an attribute value — write ' as &apos;, "" as &quot;, & as &amp;. Use ONLY the DTL elements and the HL7 paths given in the system prompt; add no methods or [ CodeMode ] members." _ nl _ nl
	set p = p _ "Return the COMPLETE corrected DTL class only (a ```objectscript fence is allowed), no prose." _ nl
	quit p
}

/// Auto-repair prompt when the DTL compiled but FAILED AT RUNTIME on the input.
/// LEAN (see CompileFixPrompt): the HL7 schema is in the cached system prompt; we
/// send only the error + a pointer, not the schema again.
ClassMethod RuntimeFixPrompt(pErrors As %String, pSrcDocType As %String, pTgtDocType As %String) As %String
{
	set nl = $char(10)
	set p = "Your DTL COMPILED but FAILED AT RUNTIME when transforming the example input. Fix the cause and return the COMPLETE corrected class (same class name and DocTypes)." _ nl _ nl
	set p = p _ "RUNTIME ERROR:" _ nl _ pErrors _ nl _ nl
	set p = p _ "Likely causes: a source path that does not exist in DocType '" _ pSrcDocType _ "', a target path that does not exist in '" _ pTgtDocType _ "', a missing repetition index on a repeating field, or a segment inside a group referenced without its group prefix. Use ONLY the HL7 paths listed in the system prompt above." _ nl
	set p = p _ "Return the COMPLETE corrected DTL class only, no prose." _ nl
	quit p
}

/// Repair prompt when the candidate compiled + ran but the accuracy GATE found
/// problems — unmet spec rules (from the LLM judge) and/or rules that produced NO
/// change in the output (coverage check). This is the accuracy feedback the old
/// compile+run gate never produced. Spec is in the cached system prompt; we send
/// only the concrete findings to fix.
ClassMethod GateFixPrompt(pFindings As %String) As %String
{
	set nl = $char(10)
	set p = "Your DTL compiled and ran, but an automated review against the APPROVED SPECIFICATION (in the system prompt above) found it does NOT yet implement every rule correctly. Fix these specific problems and return the COMPLETE corrected class (same class name and DocTypes):" _ nl _ nl
	set p = p _ pFindings _ nl _ nl
	set p = p _ "For each item, add or correct the <assign>/<if> so the produced output satisfies that spec rule. Do not regress rules that already work. Return the COMPLETE corrected DTL class only, no prose." _ nl
	quit p
}

/// Lean plan prompt for the structured-spec build flow. The approved spec + HL7
/// schema are already in the cached system prompt, so we only issue the
/// instruction — no spec/schema re-embedding.
ClassMethod PlanFromSpecPrompt() As %String
{
	set nl = $char(10)
	set p = "Before writing any DTL, produce a PLAN of how you will implement the APPROVED SPECIFICATION above, for a human to review." _ nl
	set p = p _ "SCOPE: this DTL transforms ONE message type — the one whose HL7 schema is given in the system prompt above. The specification may cover several message types; consider ONLY the rules that apply to THIS message type (i.e. rules about segments/fields that exist in this message's structure, plus genuinely cross-message rules). Do NOT list, and do NOT enumerate as 'not applicable', rules that belong to other message types — simply omit them. This keeps the plan focused and realistically sized." _ nl _ nl
	set p = p _ "Output ONLY a numbered markdown list, ONE LINE PER APPLICABLE RULE, in spec order. Every rule that applies to this message type MUST appear (the reviewer uses this list to confirm nothing in-scope was dropped) — but rules for other message types must NOT appear at all." _ nl _ nl
	set p = p _ "For each applicable rule, classify it and state concretely how the DTL will satisfy it. Apply these tests IN ORDER — the FIRST that matches wins:" _ nl
	set p = p _ "1. CONDITIONAL REQUIREMENT (highest priority). If the rule says a field is 'required if/when …', 'must be present when …', or otherwise mandates a value UNDER A CONDITION (e.g. 'field A is required when field B is populated'), it is a RUNTIME rule — implement it as DTL logic: an <if> that, WHEN the condition holds, ensures the field carries the required value. This is true EVEN IF the rule also mentions a code table, allowed values, or a max length — those describe WHAT the value must be, they do NOT downgrade a conditional requirement to pass-through. Never mark such a rule 'passed through' just because the source usually already has the value: the DTL must guarantee it when the condition is met. State the rule's real CONDITION and ACTION faithfully; do not substitute an easier condition." _ nl
	set p = p _ "2. UNCONDITIONAL ACTION. If the rule tells you to SET, MAP, NORMALISE, DEFAULT, or DERIVE a value (no condition), implement that action directly." _ nl
	set p = p _ "3. PURE VALIDITY CONSTRAINT. ONLY if the rule merely constrains what an already-present value may be (a max length, a code table, or an allowed-values list) WITHOUT any conditional requirement or action — and the source already supplies a valid value — is it satisfied by passing the value through. A stated max length is NEVER an instruction to truncate; do not invent a transform the rule does not ask for." _ nl
	set p = p _ "Marking: a rule that falls under (3) and needs no transform is still listed, followed by ' — passed through unchanged (no transform needed)'. Tests (1) and (2) must NOT be marked pass-through. Never omit an in-scope rule silently." _ nl _ nl
	set p = p _ "Do NOT write any DTL code yet. Keep each item to one line." _ nl
	quit p
}

/// Re-plan feedback: the previous plan dropped some IN-SCOPE specification rules.
/// Generic (no segment names baked in) — the caller supplies the list of rule lines
/// that apply to this message type but were not found in the plan. The model must add
/// them (implementing conditional/runtime rules as logic), without dropping anything
/// it already had. The missing list is already scoped to this message type, so every
/// listed rule genuinely belongs in the plan — none should be marked 'not applicable'.
ClassMethod PlanCoverageFixPrompt(pMissing As %String) As %String
{
	set nl = $char(10)
	set p = "Your plan dropped some rules that DO apply to this message type. The reviewer requires that every in-scope specification rule appears in the plan so nothing is silently dropped." _ nl _ nl
	set p = p _ "These applicable specification rules were missing from your plan:" _ nl
	set p = p _ pMissing _ nl _ nl
	set p = p _ "Return the COMPLETE updated plan (same numbered one-line-per-rule format), now including a line for EACH of the above (these all apply to this message type — do NOT mark any of them 'not applicable'). A conditional / 'required when…' rule is a RUNTIME rule — implement it as DTL logic (an <if> that applies when the condition holds), do NOT omit it; state its true condition and action faithfully (a max-length/code-table is a validity constraint, not a truncate instruction). Do not drop any item you already had, and do not add rules for other message types." _ nl
	quit p
}

/// Re-plan feedback: the previous plan marked CONDITIONALLY-REQUIRED rules as
/// 'passed through unchanged', which is wrong — a 'required when…' rule must be
/// enforced by DTL logic, not left to chance. Generic (caller supplies the offending
/// rule lines). The model must convert each to an <if> that guarantees the field when
/// the condition holds.
ClassMethod PlanConditionalFixPrompt(pRules As %String) As %String
{
	set nl = $char(10)
	set p = "Some rules in your plan were marked 'passed through unchanged (no transform needed)', but they are CONDITIONAL REQUIREMENTS — the specification says the field is REQUIRED when a condition holds. A conditional requirement must be GUARANTEED by the DTL, not assumed to already be present, so it cannot be pass-through." _ nl _ nl
	set p = p _ "Re-classify these rules as RUNTIME rules:" _ nl
	set p = p _ pRules _ nl _ nl
	set p = p _ "Return the COMPLETE updated plan (same numbered one-line-per-rule format). For EACH rule above, replace the 'passed through' line with one that states the CONDITION and the ACTION the DTL will take — e.g. 'when <condition> holds, ensure <field> contains <the required value/code>' (an <if> that sets/derives the value when the condition is met). A code table or max length describes what the value must be; it does NOT make the rule pass-through. Do not drop any item you already had, and do not change rules that are genuinely unconditional pass-through." _ nl
	quit p
}

/// Lean initial-generation prompt for the structured-spec build flow.
/// IMPORTANT: the example INPUT message is NOT sent to the model — the DTL is
/// derived ENTIRELY from the approved specification (the input is used only locally,
/// to derive the DocType for the HL7 schema in the system prompt and to verify the
/// compiled DTL). The transform is keyed off the message DocType, so it applies to
/// every message of that type, not just one example.
ClassMethod InitialFromSpecPrompt(pClassName As %String, pSrcDocType As %String, pTgtDocType As %String) As %String
{
	set nl = $char(10)
	set p = "Now write the DTL class named '" _ pClassName _ "' that implements the APPROVED SPECIFICATION above." _ nl
	set p = p _ "Pin sourceDocType='" _ pSrcDocType _ "' and targetDocType='" _ pTgtDocType _ "'. Implement EVERY rule in the specification that applies to this message type. The HL7 schema for these DocTypes is in the system prompt — use only those paths." _ nl _ nl
	set p = p _ "Derive the transformation from the SPECIFICATION ONLY; do not assume any particular field values — the DTL must be correct for ANY message of this type, not a single example. The class must COMPILE and produce a valid transform." _ nl
	quit p
}

/// Render an HL7 string with one segment per line for prompt readability.
ClassMethod PrettyHL7(pHL7 As %String) As %String
{
	set s = ##class(DTL.Util.HL7).ToCR(pHL7)
	quit $translate(s, $char(13), $char(10))
}

/// Build the combined source+target HL7 schema block to inject into a prompt so
/// the model knows the exact valid segment paths and field numbers for both the
/// message it reads and the one it writes. Returns "" if neither resolves.
ClassMethod SchemaBlock(pSrcDocType As %String, pTgtDocType As %String = "") As %String
{
	set nl = $char(10)
	set tSrc = ##class(DTL.Util.HL7Schema).SchemaText(pSrcDocType, 0)
	set tBlock = ""
	if tSrc '= "" set tBlock = "=== SOURCE " _ tSrc
	// Only emit the target schema separately when it differs from the source.
	if (pTgtDocType '= ""), (pTgtDocType '= pSrcDocType) {
		set tTgt = ##class(DTL.Util.HL7Schema).SchemaText(pTgtDocType, 0)
		if tTgt '= "" set tBlock = tBlock _ $select(tBlock'="":nl, 1:"") _ "=== TARGET " _ tTgt
	} elseif (pTgtDocType = pSrcDocType) || (pTgtDocType = "") {
		if tBlock '= "" set tBlock = tBlock _ nl _ "(The target message uses the SAME schema as the source.)" _ nl
	}
	quit tBlock
}

}
