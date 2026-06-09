/// HL7v2 helper utilities shared by the framework: DocType derivation,
/// line-ending normalization, and segment/field enumeration for diffing.
Class DTL.Util.HL7 Extends %RegisteredObject
{

/// Derive the DocType string "version:structure" from a raw HL7 message by
/// reading MSH-9 (message type^trigger) and MSH-12 (version) and resolving the
/// structure via the HL7 schema. Returns "" if it cannot be resolved.
/// IMPORTANT: the structure is NOT always type_trigger — e.g. 2.3 ADT^A08 maps
/// to the ADT_A01 structure. ResolveSchemaTypeToDocType handles that.
ClassMethod DeriveDocType(pHL7 As %String, Output pVersion As %String, Output pStructure As %String) As %String
{
	set pVersion = "", pStructure = ""
	try {
		// Parse the raw MSH segment directly — GetValueAt needs a DocType already
		// poked, which is exactly what we are trying to derive (chicken-and-egg).
		set tRaw = ..ToCR(pHL7)
		set tMSH = $piece(tRaw, $char(13), 1)
		if $piece(tMSH, "|", 1) '= "MSH" return ""
		// MSH-1 is the field separator, so MSH-9 = piece 9, MSH-12 = piece 12.
		set tField9 = $piece(tMSH, "|", 9)
		set pVersion = $piece(tMSH, "|", 12)
		// MSH-9 is "type^trigger^structure"; use an explicit structure (9.3) if present.
		set tType = $piece(tField9, "^", 1)
		set tTrigger = $piece(tField9, "^", 2)
		set tExplicitStruct = $piece(tField9, "^", 3)
		if pVersion = "" return ""
		// Resolve the message STRUCTURE via the schema (e.g. 2.3 ADT^A08 -> ADT_A01).
		set tTypeArg = $select(tTrigger'="":tType _ "_" _ tTrigger, 1:tType)
		set tDocType = ##class(EnsLib.HL7.Schema).ResolveSchemaTypeToDocType(pVersion, tTypeArg)
		if tDocType = "" {
			// Fall back to explicit structure from MSH-9.3, else type_trigger.
			set tStruct = $select(tExplicitStruct'="":tExplicitStruct, tTrigger'="":tType _ "_" _ tTrigger, 1:tType)
			set tDocType = pVersion _ ":" _ tStruct
		}
		set pStructure = $piece(tDocType, ":", 2)
	} catch ex {
		return ""
	}
	quit tDocType
}

/// Parse a raw HL7 string into an EnsLib.HL7.Message, normalizing line endings
/// to CR and poking the DocType if supplied so paths resolve.
ClassMethod Parse(pHL7 As %String, pDocType As %String = "", Output pStatus As %Status) As EnsLib.HL7.Message
{
	set pStatus = $$$OK
	set tRaw = ..ToCR(pHL7)
	set tMsg = ##class(EnsLib.HL7.Message).ImportFromString(tRaw, .pStatus)
	if $$$ISOK(pStatus), $isobject(tMsg), pDocType'="" {
		do tMsg.PokeDocType(pDocType)
	}
	quit tMsg
}

/// Normalize line endings to a single CR per segment terminator and strip any
/// trailing terminators (CR/LF) so import and comparison are stable.
ClassMethod ToCR(pHL7 As %String) As %String
{
	// CRLF -> CR, lone LF -> CR
	set s = $replace(pHL7, $char(13, 10), $char(13))
	set s = $translate(s, $char(10), $char(13))
	// collapse accidental double CR
	while s [ $char(13, 13) { set s = $replace(s, $char(13, 13), $char(13)) }
	quit ..StripTrailing(s, $char(13))
}

/// Remove all trailing occurrences of pChar from pStr.
ClassMethod StripTrailing(pStr As %String, pChar As %String) As %String
{
	while ($length(pStr) > 0) && ($extract(pStr, *) = pChar) {
		set pStr = $extract(pStr, 1, *-1)
	}
	quit pStr
}

/// Build a list of "SegName:Index" -> raw segment string maps, returning two
/// parallel structures via output: pSegNames(i)=name, pSegRaw(i)=full segment.
/// Used by the verifier to diff field by field with correct MSH offset handling.
ClassMethod EnumSegments(pHL7 As %String, Output pSeg) As %Integer
{
	kill pSeg
	set tRaw = ..ToCR(pHL7)
	set tList = $listfromstring(tRaw, $char(13))
	set n = 0
	set ptr = 0
	while $listnext(tList, ptr, tSeg) {
		continue:tSeg=""
		set n = n + 1
		set pSeg(n) = tSeg
		set pSeg(n, "name") = $piece(tSeg, "|", 1)
	}
	quit n
}

/// Return the field at 1-based HL7 field number pField within raw segment pSeg,
/// correctly handling MSH where MSH-1 is the field separator "|" and MSH-2 is
/// the encoding characters. For MSH, field f lives at piece (f) but the first
/// separator is itself MSH-1, so MSH-3 = $piece(seg,"|",3), MSH-1="|", MSH-2=enc.
ClassMethod FieldOf(pSeg As %String, pField As %Integer, pIsMSH As %Boolean = 0) As %String
{
	set tSegName = $piece(pSeg, "|", 1)
	if pIsMSH || (tSegName = "MSH") {
		// MSH-1 is the field separator character itself.
		if pField = 1 quit "|"
		// MSH-2 = encoding chars = piece 2; MSH-3 = piece 3; etc.
		quit $piece(pSeg, "|", pField)
	}
	// Non-MSH: field 1 = segment name (piece 1); field N = piece N+1.
	quit $piece(pSeg, "|", pField + 1)
}

/// Count the number of HL7 fields in a raw segment (excluding the segment name
/// for non-MSH; for MSH the separator counts as field 1).
ClassMethod FieldCount(pSeg As %String, pIsMSH As %Boolean = 0) As %Integer
{
	set tSegName = $piece(pSeg, "|", 1)
	set tPieces = $length(pSeg, "|")
	if pIsMSH || (tSegName = "MSH") {
		quit tPieces
	}
	quit tPieces - 1
}

}
