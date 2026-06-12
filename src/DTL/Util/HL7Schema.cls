/// Renders the InterSystems-stored HL7 v2 schema for a given DocType
/// ("version:structure", e.g. 2.5:ORU_R01) into a concise, LLM-friendly text
/// block so the model knows the EXACT segment paths and field numbers that are
/// valid for the message it is transforming. Without this, the LLM guesses paths
/// (wrong group prefixes, non-existent fields, missing repetition indexes) and the
/// generated DTL silently produces wrong output.
///
/// The data comes from EnsLib.HL7.Schema:GetContentArray, which returns the full
/// message structure tree (groups + segments) with each segment's fields inline.
/// We copy it into a process-private global (^||DTL.Schema) so that the recursive
/// walk can use dynamic-depth name indirection — indirection does NOT resolve a
/// ByRef local-array parameter across method frames, but it DOES resolve a PPG.
Class DTL.Util.HL7Schema Extends %RegisteredObject
{

/// Build the schema text for a DocType. Returns "" if the DocType cannot be
/// resolved (so callers can simply omit the block). pMaxFields caps how many
/// fields per segment are listed (0 = all) to keep the prompt bounded.
ClassMethod SchemaText(pDocType As %String, pMaxFields As %Integer = 0) As %String
{
	set nl = $char(10)
	if pDocType = "" return ""
	set tVer = $piece(pDocType, ":", 1)
	set tStruct = $piece(pDocType, ":", 2)
	if (tVer = "") || (tStruct = "") return ""
	kill ^||DTL.Schema
	try {
		do ##class(EnsLib.HL7.Schema).GetContentArray(.tC, "source", pDocType, , 0, 0)
		if $get(tC) = "" return ""
		merge ^||DTL.Schema = tC

		// Walk the structure tree -> group-prefixed segment paths + the set of
		// distinct segment types (each mapped to the PPG node holding its fields).
		kill tSegTypes
		set tPathLines = ""
		do ..WalkStruct("", "", .tSegTypes, .tPathLines, 0)

		set p = "HL7 SCHEMA for DocType '" _ pDocType _ "' (read from the IRIS HL7 schema store). Use ONLY these segment paths and field numbers — any other path or field number is invalid and will silently produce no output." _ nl _ nl
		set p = p _ "MESSAGE STRUCTURE — the exact brace path to each segment. A trailing () marks a REPEATING segment or group that REQUIRES a repetition index; the path below already shows the index as (1). Segments inside a group MUST be written with the full group prefix shown here:" _ nl
		set p = p _ tPathLines _ nl

		set p = p _ "SEGMENT FIELDS — field number = field name (a trailing () marks a repeating field that needs a repetition index, e.g. {PID:3(1)}):" _ nl
		set tSeg = ""
		for {
			set tSeg = $order(tSegTypes(tSeg))
			quit:tSeg=""
			set p = p _ ..SegmentFieldLines(tSegTypes(tSeg), tSeg, pMaxFields)
		}
		kill ^||DTL.Schema
		return p
	} catch ex {
		kill ^||DTL.Schema
		return ""
	}
}

/// The SET of distinct segment names present in a message structure, as a
/// ",MSH,PID,OBR,…," delimited string (leading+trailing comma for easy [ membership
/// tests). Used to scope plan-coverage to rules whose segment actually exists in this
/// message type — so rules for OTHER message types (ACK/SIU/REF segments not in an
/// ORU_R01, etc.) are neither demanded nor enumerated. Returns "" if the DocType
/// doesn't resolve (caller then falls back to enforcing all rules).
ClassMethod SegmentSet(pDocType As %String) As %String
{
	if pDocType = "" return ""
	kill ^||DTL.Schema
	try {
		do ##class(EnsLib.HL7.Schema).GetContentArray(.tC, "source", pDocType, , 0, 0)
		if $get(tC) = "" { kill ^||DTL.Schema  return "" }
		merge ^||DTL.Schema = tC
		kill tSegTypes
		set tLines = ""
		do ..WalkStruct("", "", .tSegTypes, .tLines, 0)
		set tOut = ",", tSeg = ""
		for { set tSeg = $order(tSegTypes(tSeg))  quit:tSeg=""  set tOut = tOut _ $zconvert(tSeg, "U") _ "," }
		kill ^||DTL.Schema
		return $select(tOut=",":"", 1:tOut)
	} catch {
		kill ^||DTL.Schema
		return ""
	}
}

/// Recursively walk the content tree in ^||DTL.Schema. Emits one line per segment
/// with its full DTL group-prefixed path and records each distinct segment type.
///   pNode   = complete subscript string of the current parent ("" = top level,
///             then "1", then "3,1", …) — children are pNode_","_key.
///   pPrefix = DTL path prefix from enclosing groups (e.g. "PIDgrpgrp(1).PIDgrp.").
ClassMethod WalkStruct(pNode As %String, pPrefix As %String, ByRef pSegTypes, ByRef pLines As %String, pDepth As %Integer)
{
	set nl = $char(10)
	set k = ""
	for {
		set k = ..NextNumChild(pNode, k)
		quit:k=""
		set tChildNode = $select(pNode="":k, 1:pNode _ "," _ k)
		set tName = ..Leaf(tChildNode, "name")
		set tType = ..Leaf(tChildNode, "type")
		continue:tName=""
		set tIsSeg = ($extract(tType, 1, 3) = "SS:")
		set tIsGrp = (tType [ "grp")
		if tIsSeg {
			// Segment leaf: DTL path = prefix _ name. Make the repetition index
			// explicit: a segment marked NAME() repeats, so show NAME(1).
			set tDisp = $select(tName [ "()":$piece(tName, "()", 1) _ "(1)", 1:tName)
			set pLines = pLines _ ..Indent(pDepth) _ "{" _ pPrefix _ tDisp _ ":...}" _ nl
			set tCode = $translate($piece(tType, ":", 3), "()", "")   // SS:2.5:PID() -> PID
			if (tCode '= ""), '$data(pSegTypes(tCode)) set pSegTypes(tCode) = tChildNode
		} elseif tIsGrp {
			// Group: extend the path and recurse. A repeating group NAME() -> NAME(1).
			set tDisp = $select(tName [ "()":$piece(tName, "()", 1) _ "(1)", 1:tName)
			set pLines = pLines _ ..Indent(pDepth) _ tDisp _ " (group):" _ nl
			do ..WalkStruct(tChildNode, pPrefix _ tDisp _ ".", .pSegTypes, .pLines, pDepth + 1)
		}
	}
}

/// $order the next NUMERIC child subscript of node pNode (skips metadata leaves
/// like "name"/"type"/"opt"). pNode is the complete subscript string or "".
ClassMethod NextNumChild(pNode As %String, pKey As %String) As %String
{
	set tQ = $select(pKey="":"""""", pKey=+pKey:pKey, 1:""""_pKey_"""")
	set tRef = $select(pNode="":"^||DTL.Schema(" _ tQ _ ")", 1:"^||DTL.Schema(" _ pNode _ "," _ tQ _ ")")
	set k = $order(@tRef)
	while (k '= "") && (k '= +k) {
		set tQ = $select(k="":"""""", k=+k:k, 1:""""_k_"""")
		set tRef = $select(pNode="":"^||DTL.Schema(" _ tQ _ ")", 1:"^||DTL.Schema(" _ pNode _ "," _ tQ _ ")")
		set k = $order(@tRef)
	}
	quit k
}

/// Read leaf ^||DTL.Schema(<node>,pLeaf) via indirection. Returns "" if missing.
ClassMethod Leaf(pNode As %String, pLeaf As %String) As %String
{
	set tRef = "^||DTL.Schema(" _ pNode _ ",""" _ pLeaf _ """)"
	quit $get(@tRef)
}

/// Indent helper for the structure outline.
ClassMethod Indent(pDepth As %Integer) As %String
{
	set s = "" for i = 1:1:pDepth { set s = s _ "  " }
	quit s
}

/// Emit "  SEG: 1=Name 2=Name …" for one segment type. pNode is the PPG node
/// where this segment's field subscripts live.
ClassMethod SegmentFieldLines(pNode As %String, pSegCode As %String, pMaxFields As %Integer) As %String
{
	set nl = $char(10)
	set tLine = "  " _ pSegCode _ ":"
	set f = ""
	set tShown = 0
	for {
		set tQ = $select(f="":"""""", f=+f:f, 1:""""_f_"""")
		set tRef = "^||DTL.Schema(" _ pNode _ "," _ tQ _ ")"
		set f = $order(@tRef)
		quit:f=""
		continue:f'=+f
		set tFName = ..Leaf(pNode _ "," _ f, "name")
		continue:tFName=""
		if $extract(tFName) = ":" set tFName = $extract(tFName, 2, *)
		set tLine = tLine _ " " _ f _ "=" _ tFName
		set tShown = tShown + 1
		if (pMaxFields > 0) && (tShown >= pMaxFields) { set tLine = tLine _ " …" quit }
	}
	quit tLine _ nl
}

}
