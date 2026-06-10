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
/// Includes the verbatim ObjectScript compiler errors and a focused reminder of
/// the DTL rules most likely to be the cause, so the model can self-correct.
ClassMethod CompileFixPrompt(pErrors As %String, pSrcDocType As %String, pTgtDocType As %String) As %String
{
	set nl = $char(10)
	set p = "Your DTL did NOT COMPILE. Below are the verbatim InterSystems ObjectScript compiler errors (with line numbers and the offending generated line). Fix EVERY error and return the COMPLETE corrected class (same class name and DocTypes)." _ nl _ nl
	set p = p _ "COMPILER ERRORS:" _ nl _ pErrors _ nl _ nl
	set p = p _ "Checklist for valid DTL (the usual causes of these errors):" _ nl
	set p = p _ "- Output ONLY one complete class, wrapped in the exact shape: Class ... Extends Ens.DataTransformDTL [ DependsOn = EnsLib.HL7.Message ] with an XData DTL block containing a single <transform>...</transform>." _ nl
	set p = p _ "- The <transform> element needs sourceClass/targetClass='EnsLib.HL7.Message', sourceDocType='" _ pSrcDocType _ "', targetDocType='" _ pTgtDocType _ "', create='copy', language='objectscript'." _ nl
	set p = p _ "- Every <assign> needs value=, property= and action='set' (or 'append'/'clear'). Quote literal values inside the value attribute with double-quotes, e.g. value='""EPIC""'." _ nl
	set p = p _ "- Field paths use the brace grammar {SEG:field.component.subcomponent}; repeating fields REQUIRE a repetition index, e.g. {PID:5(1).1.1}." _ nl
	set p = p _ "- Do NOT add methods, Parameters, or [ CodeMode ] members — only the <transform>." _ nl _ nl
	// Restate the full element schema + escaping rule — the usual root causes.
	set p = p _ ..DtlSchema() _ nl
	set p = p _ ..XmlEscapingRule() _ nl
	set p = p _ "If the errors mention a parse/SAX error, an unexpected ' or "" , or a truncated attribute, it is almost certainly an UNESCAPED character inside an attribute value — apply the entity rule above." _ nl _ nl
	set p = p _ "Return the COMPLETE corrected DTL class only (a ```objectscript fence is allowed), no prose." _ nl
	quit p
}

/// Auto-repair prompt when the DTL compiled but FAILED AT RUNTIME on the input.
ClassMethod RuntimeFixPrompt(pErrors As %String, pSrcDocType As %String, pTgtDocType As %String) As %String
{
	set nl = $char(10)
	set p = "Your DTL COMPILED but FAILED AT RUNTIME when transforming the example input. Fix the cause and return the COMPLETE corrected class (same class name and DocTypes)." _ nl _ nl
	set p = p _ "RUNTIME ERROR:" _ nl _ pErrors _ nl _ nl
	set p = p _ "Likely causes: a source path that does not exist in DocType '" _ pSrcDocType _ "', a target path that does not exist in '" _ pTgtDocType _ "', a missing repetition index on a repeating field, or referencing a segment inside a group without its group prefix." _ nl
	set tSchema = ..SchemaBlock(pSrcDocType, pTgtDocType)
	if tSchema '= "" set p = p _ "Use ONLY these valid paths:" _ nl _ tSchema _ nl
	set p = p _ "Return the COMPLETE corrected DTL class only, no prose." _ nl
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
