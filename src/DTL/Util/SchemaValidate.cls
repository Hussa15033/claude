/// <class>DTL.Util.SchemaValidate</class> — validate a PRODUCED HL7 message against
/// its target DocType schema, the exact manual step that is the implementation
/// partner's headache today ("build the DTL, then read the schema by hand to see if
/// the output is good"). This automates it: it parses the produced message, pokes the
/// target DocType, and runs InterSystems' own message validator, decomposing the
/// result into a structured, UI-renderable list of findings (missing required segment,
/// bad field datatype, cardinality, code-table membership, …).
///
/// It is also a far stronger feedback signal for the regeneration loop than the old
/// "did any field change?" heuristic: a structural defect in the output is concrete,
/// IRIS-authoritative, and tells the LLM exactly which segment/field to fix.
///
/// Validation spec "dm" (proven live): d = validate against the DocType definition,
/// m = enforce required (mandatory) segments. The validator returns a %Status whose
/// nested errors carry "<EnsEDI>ErrMapRequired: Missing required EVN element at
/// segment 2 (PID)"-style messages, which we parse into {kind, segment, field,
/// message, severity}.
Class DTL.Util.SchemaValidate Extends %RegisteredObject
{

/// Default validation spec. d=against DocType, m=required segments enforced.
Parameter SPEC = "dm";

/// Validate pHL7 against pDocType. Returns a %DynamicObject:
///   { valid:Bool, docType, findingCount, findings:[ {kind, segment, field,
///       severity, message} ], error }
/// valid=true means the message conforms (no findings). If the message can't even be
/// parsed, valid=false with a single PARSE finding. pDocType blank => can't validate
/// (returns valid=true, a NOTE finding) so the caller never hard-fails on a missing
/// target DocType.
ClassMethod Validate(pHL7 As %String, pDocType As %String, pSpec As %String = "") As %DynamicObject
{
	set tRes = {}
	set tRes.docType = pDocType
	set tRes.findings = []
	set tRes.valid = 1
	set tRes.findingCount = 0
	set tRes.error = ""
	if pSpec = "" set pSpec = ..#SPEC
	if $zstrip($get(pHL7), "<>W") = "" {
		set tRes.valid = 0
		do tRes.findings.%Push({"kind":"PARSE", "segment":"", "field":"", "severity":"HIGH", "message":"The transform produced an empty message."})
		set tRes.findingCount = 1
		quit tRes
	}
	if pDocType = "" {
		do tRes.findings.%Push({"kind":"NOTE", "segment":"", "field":"", "severity":"LOW", "message":"No target DocType known — output structure not schema-checked."})
		quit tRes
	}
	try {
		set tMsg = ##class(EnsLib.HL7.Message).ImportFromString(##class(DTL.Util.HL7).ToCR(pHL7), .isc)
		if $$$ISERR(isc) || '$isobject(tMsg) {
			set tRes.valid = 0
			do tRes.findings.%Push({"kind":"PARSE", "segment":"", "field":"", "severity":"HIGH", "message":("Produced message does not parse as HL7: " _ $system.Status.GetErrorText(isc))})
			set tRes.findingCount = 1
			quit
		}
		do tMsg.PokeDocType(pDocType)
		set vsc = tMsg.Validate(pSpec)
		if $$$ISOK(vsc) quit                       // conforms — valid stays 1, no findings
		set tRes.valid = 0
		do ..Decompose(vsc, tRes.findings)
		set tRes.findingCount = tRes.findings.%Size()
	} catch ex {
		set tRes.valid = 0
		set tRes.error = ex.DisplayString()
		do tRes.findings.%Push({"kind":"ERROR", "segment":"", "field":"", "severity":"HIGH", "message":("Validation raised: " _ ex.DisplayString())})
		set tRes.findingCount = tRes.findings.%Size()
	}
	quit tRes
}

/// Decompose a validation %Status into structured findings appended to pArr. Each
/// nested error is parsed for a segment ordinal/name and a field/element reference so
/// the UI can point straight at the offending location. De-duplicated.
ClassMethod Decompose(pStatus As %Status, pArr As %DynamicArray)
{
	kill tSeen
	do $system.Status.DecomposeStatus(pStatus, .tErrs)
	set i = ""
	for {
		set i = $order(tErrs(i))
		quit:i=""
		set tTxt = $get(tErrs(i))
		continue:tTxt=""
		set tTxt = ##class(DTL.Util.Verifier).CleanErrLine(tTxt)
		continue:tTxt=""
		continue:$data(tSeen(tTxt))
		set tSeen(tTxt) = 1
		set tF = {}
		set tF.message = tTxt
		set tF.kind = ..ClassifyKind(tTxt)
		set tF.severity = ..ClassifySeverity(tF.kind)
		do ..LocateInText(tTxt, .tSeg, .tField)
		set tF.segment = tSeg
		set tF.field = tField
		do pArr.%Push(tF)
	}
	// If decomposition yielded nothing usable, fall back to the rendered status text.
	if pArr.%Size() = 0 {
		set tTxt = ##class(DTL.Util.Verifier).CleanErrLine($system.Status.GetErrorText(pStatus))
		if tTxt '= "" do pArr.%Push({"kind":"OTHER", "segment":"", "field":"", "severity":"MED", "message":(tTxt)})
	}
}

/// Classify a validator message into a coarse kind the UI can group/icon by.
ClassMethod ClassifyKind(pTxt As %String) As %String
{
	set l = $zconvert(pTxt, "L")
	if (l [ "required") || (l [ "missing") quit "MISSING_REQUIRED"
	if (l [ "repetition") || (l [ "repeat") || (l [ "cardinalit") || (l [ "too many") || (l [ "occurs") quit "CARDINALITY"
	if (l [ "code") || (l [ "table") || (l [ "not in") || (l [ "illegal value") quit "CODE_TABLE"
	if (l [ "length") || (l [ "too long") || (l [ "maximum") quit "LENGTH"
	if (l [ "datatype") || (l [ "data type") || (l [ "format") || (l [ "invalid") quit "DATATYPE"
	if (l [ "unknown segment") || (l [ "unrecognized") || (l [ "no such segment") quit "UNKNOWN_SEGMENT"
	quit "OTHER"
}

/// Severity policy: a missing required element / unknown segment is a HIGH structural
/// defect; cardinality/datatype are MED; code-table/length are LOW (often advisory).
ClassMethod ClassifySeverity(pKind As %String) As %String
{
	quit $case(pKind,
		"MISSING_REQUIRED":"HIGH", "UNKNOWN_SEGMENT":"HIGH",
		"CARDINALITY":"MED", "DATATYPE":"MED",
		"CODE_TABLE":"LOW", "LENGTH":"LOW",
		:"MED")
}

/// Best-effort extraction of a segment name + field/element reference from a validator
/// message. Examples seen live: "... at segment 2 (PID)", "... element 5 in segment
/// PID". Sets pSeg (segment name or ordinal) and pField ("" if none found).
ClassMethod LocateInText(pTxt As %String, Output pSeg As %String, Output pField As %String)
{
	set pSeg = "", pField = ""
	// "(SEGNAME)" — a parenthesised 2-4 char upper segment name.
	set tOpen = 0
	for i = 1:1:$length(pTxt) {
		if $extract(pTxt, i) = "(" {
			set tClose = $find(pTxt, ")", i)
			continue:tClose=0
			set tInner = $extract(pTxt, i + 1, tClose - 2)
			if (tInner ? 2.4U) || (tInner ? 1U.3UN) { set pSeg = tInner  quit }
		}
	}
	// "segment N" — capture the ordinal if we didn't get a name.
	if pSeg = "" {
		set tP = $find($zconvert(pTxt, "L"), "segment ")
		if tP > 0 {
			set tNum = ""
			for j = tP:1:$length(pTxt) { set ch = $extract(pTxt, j)  quit:'(ch?1N)  set tNum = tNum _ ch }
			if tNum '= "" set pSeg = "#" _ tNum
		}
	}
	// "element N" / "field N" -> field number.
	for tag = "element ", "field " {
		set tP = $find($zconvert(pTxt, "L"), tag)
		continue:tP=0
		set tNum = ""
		for j = tP:1:$length(pTxt) { set ch = $extract(pTxt, j)  quit:'(ch?1N)  set tNum = tNum _ ch }
		if tNum '= "" { set pField = tNum  quit }
	}
}

/// Render a findings array as a compact text block for the repair feedback prompt.
/// HIGH first. Returns "" when there are no findings.
ClassMethod FindingsToText(pFindings As %DynamicArray, pMax As %Integer = 20) As %String
{
	quit:'$isobject(pFindings) ""
	set nl = $char(10), tHigh = "", tRest = "", n = 0
	set it = pFindings.%GetIterator()
	while it.%GetNext(.k, .f) {
		continue:'$isobject(f)
		set tLoc = ""
		if f.segment '= "" set tLoc = " [" _ f.segment _ $select(f.field'="":"-" _ f.field, 1:"") _ "]"
		set tLine = "- [" _ f.severity _ "] " _ f.message _ tLoc
		if f.severity = "HIGH" { set tHigh = tHigh _ tLine _ nl } else { set tRest = tRest _ tLine _ nl }
		set n = n + 1
		quit:n>=pMax
	}
	quit tHigh _ tRest
}

}
