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
	set p = p _ "Use <if condition='...'><true>...</true><false>...</false></if> for conditional logic, e.g. code mapping." _ nl
	set p = p _ "The sourceDocType/targetDocType are the message STRUCTURE 'version:structure' (e.g. 2.3:ADT_A01). Note an HL7 2.3 ADT^A08 uses the ADT_A01 structure. Use exactly the DocTypes given to you." _ nl
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
	set p = p _ "SPECIFICATION:" _ nl _ pSpec _ nl _ nl
	if pInputsBlock '= "" {
		set p = p _ "Example INPUT messages this DTL must handle:" _ nl _ pInputsBlock _ nl _ nl
	}
	set p = p _ "Output ONLY a numbered markdown list of the concrete changes the DTL will make (segment/field level). No DTL code yet. Keep it under 12 bullets." _ nl
	quit p
}

/// SPEC-DRIVEN initial generation prompt (no expected output to match against).
ClassMethod SpecInitialPrompt(pSpec As %String, pSrcDocType As %String, pTgtDocType As %String, pPrimaryInput As %String, pClassName As %String) As %String
{
	set nl = $char(10)
	set p = "Write a DTL class named '" _ pClassName _ "' that implements the transformation described in the specification." _ nl
	set p = p _ "Pin sourceDocType='" _ pSrcDocType _ "' and targetDocType='" _ pTgtDocType _ "'." _ nl _ nl
	set p = p _ "There are NO example output messages. Implement the rules from the spec/plan above. The DTL must COMPILE and RUN without error on the example input." _ nl _ nl
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
	set p = p _ "- XML attribute values are single-quoted; escape special XML chars (&amp; &lt; &gt;) inside them." _ nl
	set p = p _ "- Do NOT add methods, Parameters, or [ CodeMode ] members — only the <transform>." _ nl _ nl
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
	set p = p _ "Return the COMPLETE corrected DTL class only, no prose." _ nl
	quit p
}

/// Render an HL7 string with one segment per line for prompt readability.
ClassMethod PrettyHL7(pHL7 As %String) As %String
{
	set s = ##class(DTL.Util.HL7).ToCR(pHL7)
	quit $translate(s, $char(13), $char(10))
}

}
