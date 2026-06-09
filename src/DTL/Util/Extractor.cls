/// Extracts a clean InterSystems DTL class definition from a raw LLM reply.
/// Handles: markdown code fences (```objectscript ... ```), surrounding prose,
/// and reports the class name. Validates that the result looks like a DTL.
Class DTL.Util.Extractor Extends %RegisteredObject
{

/// Extract a compilable class definition from raw LLM content.
/// Returns the class source (or "" if none found); sets pClassName and pValid.
ClassMethod Extract(pRaw As %String, Output pClassName As %String, Output pValid As %Boolean) As %String
{
	set pClassName = "", pValid = 0
	set tText = pRaw

	// 1. If there is a fenced block, take the first fenced block's body.
	if tText [ "```" {
		set tInner = ..FirstFencedBlock(tText)
		if tInner '= "" set tText = tInner
	}

	// 2. Slice from the first "Class <name> Extends" to the matching final "}".
	set tStart = ..FindClassStart(tText)
	if tStart > 0 {
		set tText = $extract(tText, tStart, *)
		set tEnd = ..LastBrace(tText)
		if tEnd > 0 set tText = $extract(tText, 1, tEnd)
	}

	set tText = $zstrip(tText, "<>W", $char(10, 13, 9, 32))
	// recover from over-stripping inner content: only trim outer whitespace
	set tText = ..TrimOuter(pRaw, tText)

	// 3. Parse class name + validate.
	do ##class(DTL.Util.Verifier).ExtractClassName(tText, .pClassName)
	set tU = $zconvert(tText, "U")
	set pValid = (tU [ "EXTENDS ENS.DATATRANSFORMDTL") && (tU [ "XDATA") && (pClassName '= "")
	quit tText
}

/// Return the body of the first ```...``` fenced block, language tag removed.
ClassMethod FirstFencedBlock(pText As %String) As %String
{
	set tOpen = $find(pText, "```")
	quit:tOpen=0 ""
	// Skip an optional language tag up to end of that line.
	set tNL = $find(pText, $char(10), tOpen)
	if tNL = 0 set tNL = tOpen
	set tClose = $find(pText, "```", tNL)
	if tClose = 0 {
		// Unterminated fence: take the rest after the opening line.
		quit $extract(pText, tNL, *)
	}
	// Body is between tNL and the start of the closing fence (tClose-3).
	quit $extract(pText, tNL, tClose - 4)
}

/// Find the 1-based position where "Class <x> Extends" begins (case-insensitive).
ClassMethod FindClassStart(pText As %String) As %Integer
{
	set tU = $zconvert(pText, "U")
	// Look for "CLASS " followed later on the line by "EXTENDS".
	set tPos = 1
	for {
		set tFound = $find(tU, "CLASS ", tPos)
		quit:tFound=0
		set tLineEnd = $find(tU, $char(10), tFound)
		if tLineEnd = 0 set tLineEnd = $length(tU) + 1
		set tLine = $extract(tU, tFound, tLineEnd - 1)
		if tLine [ "EXTENDS" {
			quit  // tFound points just after "CLASS "; back up to the 'C'.
		}
		set tPos = tFound
	}
	quit:tFound=0 0
	quit tFound - 6
}

/// Return the position of the last "}" in the text (class close brace).
ClassMethod LastBrace(pText As %String) As %Integer
{
	for i = $length(pText):-1:1 {
		if $extract(pText, i) = "}" quit
	}
	quit $select($get(i)>0 && ($extract(pText, i)="}"):i, 1:0)
}

/// Helper: outer-trim only (keep inner newlines intact).
ClassMethod TrimOuter(pOriginal As %String, pCandidate As %String) As %String
{
	quit $zstrip(pCandidate, "<>W", $char(9, 32))
}

}
