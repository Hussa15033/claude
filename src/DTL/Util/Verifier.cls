/// <class>DTL.Util.Verifier</class> is the heart of the GenAI DTL feedback loop.
/// It compiles a piece of generated DTL <b>class source</b> (as returned by an
/// LLM), runs the resulting transform against a source HL7v2 message, normalizes
/// both produced and expected output, and returns a structured result describing
/// whether the DTL <i>compiled</i>, <i>ran</i>, and how closely its output
/// <i>matches</i> the expected output (subject to a configurable success policy).
///
/// All methods are stateless class methods so the utility can be called from a
/// Business Process, from unit tests, or from the terminal alike. The compile
/// step loads from an in-memory stream (no temp files), confirmed working via
/// $system.OBJ.LoadStream.
Class DTL.Util.Verifier Extends %RegisteredObject
{

/// Default class name used when the generated source is a bare &lt;transform&gt;
/// fragment rather than a full class definition.
Parameter DEFAULTDTLCLASS = "DTL.Generated.Candidate";

/// Compile a DTL class from its source text. <var>pSource</var> may be a full
/// "Class ... { XData DTL {...} }" definition or a bare &lt;transform&gt; fragment
/// (wrapped automatically into <var>pClassName</var>). On return <var>pClassName</var>
/// is the compiled class name and <var>pErrors</var> holds compiler errors (with
/// line numbers and the offending generated source line) or "" on success.
ClassMethod CompileDTL(pSource As %String, ByRef pClassName As %String = "", Output pErrors As %String) As %Status
{
	set pErrors = ""
	set tSC = $$$OK
	try {
		// SECURITY: never compile the LLM's class wrapper verbatim -- a full class
		// could smuggle a [ CodeMode = generator ] method or other members that
		// execute arbitrary ObjectScript at compile time. We extract ONLY the
		// <transform> fragment and re-wrap it ourselves into a forced, sanitized
		// DTL.Generated.* class name. This constrains both the executed code (only
		// a DTL transform) and the namespace footprint.
		set tFragment = ..ExtractTransform(pSource)
		if tFragment = "" {
			set tSC = $$$ERROR($$$GeneralError, "No <transform>...</transform> block found in the generated source.")
			quit
		}

		if pClassName = "" set pClassName = ..#DEFAULTDTLCLASS
		set pClassName = ..ForcePackage(..SanitizeClassName(pClassName))
		set tSource = ..WrapTransform(tFragment, pClassName)

		// A stale prior version must not masquerade as a fresh success.
		if ##class(%Dictionary.CompiledClass).%ExistsId(pClassName) {
			do $system.OBJ.Delete(pClassName, "-d")
		}

		set tStream = ##class(%Stream.GlobalCharacter).%New()
		do tStream.Write(tSource)
		kill tLoadErr
		set tSC = $system.OBJ.LoadStream(tStream, "ck/displayerror=0/displaylog=0", .tLoadErr)

		if $$$ISOK(tSC), '##class(%Dictionary.CompiledClass).%ExistsId(pClassName) {
			set tSC = $$$ERROR($$$GeneralError, "DTL source compiled but class '" _ pClassName _ "' was not produced.")
		}
	} catch ex {
		set tSC = ex.AsStatus()
	}
	// Build a VERBOSE, fully-decomposed error log: the compound %Status only renders
	// its top wrapper (e.g. "<Ens>ErrInvalidDTL / #5490 generator failed"), which
	// hides the actual reason the DTL is invalid. We decompose the status into every
	// nested error AND walk the LoadStream errorlog array so the LLM sees the real
	// cause (bad path, unknown property, XML error, ...) and the offending line.
	if $$$ISERR(tSC) set pErrors = ..FormatCompileErrors(tSC, .tLoadErr)
	quit tSC
}

/// Render a compile failure as a numbered, de-duplicated list of EVERY underlying
/// error. Sources, in order: (1) every error decomposed from the compound %Status
/// via $system.Status.DecomposeStatus; (2) every node of the LoadStream errorlog
/// array (which often carries class/method/line context the status text omits).
/// The result is a clean multi-line block ready to hand back to the LLM.
ClassMethod FormatCompileErrors(pStatus As %Status, ByRef pLoadErr) As %String
{
	set nl = $char(10)
	set tOut = "", n = 0
	// Track seen lines so the same error from status + errorlog isn't printed twice.
	kill tSeen

	// (1) Decompose the compound status into its constituent errors.
	if $get(pStatus) '= "", $$$ISERR(pStatus) {
		do $system.Status.DecomposeStatus(pStatus, .tErrs)
		set i = ""
		for {
			set i = $order(tErrs(i))
			quit:i=""
			set tTxt = $get(tErrs(i))
			continue:tTxt=""
			set tTxt = ..CleanErrLine(tTxt)
			continue:tTxt=""
			continue:$data(tSeen(tTxt))
			set tSeen(tTxt) = 1, n = n + 1
			set tOut = tOut _ n _ ". " _ tTxt _ nl
		}
	}

	// (2) Walk the LoadStream errorlog array (any depth). Nodes may hold a %Status
	//     or a plain text message; normalise both.
	set tKey = ""
	for {
		set tKey = $order(pLoadErr(tKey))
		quit:tKey=""
		set tVal = $get(pLoadErr(tKey))
		// A node value MAY be a real %Status ($list-encoded); only then render it via
		// GetErrorText. A plain text string (the common case) is used verbatim --
		// passing it to GetErrorText would wrongly re-wrap it as "#5034 Invalid
		// status code structure".
		set tTxt = ""
		if (tVal '= "") {
			if $listvalid(tVal) && $system.Status.IsError(tVal) {
				set tTxt = $system.Status.GetErrorText(tVal)
			} else {
				set tTxt = tVal
			}
		}
		set tTxt = ..CleanErrLine(tTxt)
		continue:tTxt=""
		continue:$data(tSeen(tTxt))
		set tSeen(tTxt) = 1, n = n + 1
		set tOut = tOut _ n _ ". " _ tTxt _ nl
	}

	if tOut = "" set tOut = $system.Status.GetErrorText(pStatus)
	quit tOut
}

/// Tidy a single error line: collapse CRLF/tabs to spaces, trim, drop a leading
/// ">" continuation marker the compiler emits, and squeeze runs of whitespace.
ClassMethod CleanErrLine(pTxt As %String) As %String
{
	set s = $translate(pTxt, $char(13, 10, 9), "   ")
	// squeeze double spaces
	while (s [ "  ") { set s = $replace(s, "  ", " ") }
	set s = $zstrip(s, "<>W")
	if $extract(s) = ">" set s = $zstrip($extract(s, 2, *), "<W")
	quit s
}

/// Extract the first &lt;transform&gt;...&lt;/transform&gt; block from arbitrary
/// generated source (a bare fragment, an XData body, or a full class). Returns
/// "" if none is present. This is the security boundary: only the transform XML
/// is ever compiled, never LLM-authored class members/methods.
ClassMethod ExtractTransform(pSource As %String) As %String
{
	set tStart = $find(pSource, "<transform")
	quit:tStart=0 ""
	set tStart = tStart - $length("<transform")
	set tEndTag = "</transform>"
	set tEnd = $find(pSource, tEndTag, tStart)
	quit:tEnd=0 ""
	quit $extract(pSource, tStart, tEnd - 1)
}

/// Force a class name into the DTL.Generated.* package, keeping only the final
/// (already-sanitized) leaf segment. Prevents an LLM-chosen name from landing in
/// a system package.
ClassMethod ForcePackage(pName As %String) As %String
{
	set tLeaf = $piece(pName, ".", $length(pName, "."))
	if tLeaf = "" set tLeaf = "Candidate"
	quit "DTL.Generated." _ tLeaf
}

/// Run a compiled DTL against a source HL7 string and return the produced HL7.
ClassMethod RunTransform(pClassName As %String, pSourceHL7 As %String, pSourceDocType As %String = "", Output pOutputHL7 As %String, Output pErrors As %String) As %Status
{
	set pOutputHL7 = "", pErrors = ""
	set tSC = $$$OK
	try {
		set tMsg = ##class(DTL.Util.HL7).Parse(pSourceHL7, pSourceDocType, .tSC)
		quit:$$$ISERR(tSC)
		set tSC = $classmethod(pClassName, "Transform", tMsg, .tOut)
		quit:$$$ISERR(tSC)
		if '$isobject($get(tOut)) {
			set tSC = $$$ERROR($$$GeneralError, "Transform produced no output object")
			quit
		}
		set pOutputHL7 = tOut.OutputToString()
	} catch ex {
		set tSC = ex.AsStatus()
	}
	if $$$ISERR(tSC) set pErrors = $system.Status.GetErrorText(tSC)
	quit tSC
}

/// Normalize an HL7 string for stable comparison: CRLF/LF -> CR, strip trailing
/// terminators (OutputToString appends a trailing CR), and blank out volatile
/// fields (MSH-7 message time, MSH-10 control id) when <var>pNeutralize</var>.
ClassMethod Normalize(pHL7 As %String, pNeutralize As %Boolean = 0) As %String
{
	set s = ##class(DTL.Util.HL7).ToCR(pHL7)
	if pNeutralize {
		set tList = $listfromstring(s, $char(13))
		set out = ""
		set ptr = 0
		while $listnext(tList, ptr, tSeg) {
			if $piece(tSeg, "|", 1) = "MSH" {
				// MSH-7 = piece 7, MSH-10 = piece 10 (MSH-1 is the separator).
				set $piece(tSeg, "|", 7) = ""
				set $piece(tSeg, "|", 10) = ""
			}
			set out = out _ $select(out'="":$char(13), 1:"") _ tSeg
		}
		set s = out
	}
	quit s
}

/// Compare actual vs expected HL7 under a success policy, returning a
/// %DynamicObject: { identical, matched, score, structScore, fieldScore,
/// diffCount, diffs[], normalizedActual, normalizedExpected }.
ClassMethod Compare(pActualHL7 As %String, pExpectedHL7 As %String, pPolicy As %String = "CompileMatch", pThreshold As %Numeric = 0.85, pSourceHL7 As %String = "") As %DynamicObject
{
	set tRes = {}
	set tNeutralize = (pPolicy = "CompileMatchTolerance")
	set tA = ..Normalize(pActualHL7, tNeutralize)
	set tE = ..Normalize(pExpectedHL7, tNeutralize)
	set tRes.normalizedActual = tA
	set tRes.normalizedExpected = tE
	set tRes.identical = (tA = tE)

	// Field-level diff + scores.
	set tDiffs = ..DiffSegments(tA, tE, pSourceHL7, .tStruct, .tField)
	set tRes.diffs = tDiffs
	set tRes.diffCount = tDiffs.%Size()
	set tRes.structScore = tStruct
	set tRes.fieldScore = tField
	set tRes.score = (0.5 * tStruct) + (0.5 * tField)

	// Decide "matched" per policy.
	if pPolicy = "CompileOnly" {
		set tRes.matched = 1
	} elseif pPolicy = "CompileRun" {
		set tRes.matched = 1
	} elseif pPolicy = "CompileMatchTolerance" {
		set tRes.matched = (tRes.score >= pThreshold)
	} else {  // CompileMatch (exact)
		set tRes.matched = tRes.identical
	}
	quit tRes
}

/// Produce a %DynamicArray of field-level differences between two normalized
/// HL7 strings, and compute structure + field scores via output args.
/// Severity is HIGH when the expected value is derivable from the source (it
/// appears somewhere in <var>pSourceHL7</var>), LOW otherwise (likely an
/// illustrative value that should NOT be hard-coded — honours the caveat).
ClassMethod DiffSegments(pActual As %String, pExpected As %String, pSourceHL7 As %String = "", Output pStructScore As %Numeric, Output pFieldScore As %Numeric) As %DynamicArray
{
	set tArr = []
	set tAn = ##class(DTL.Util.HL7).EnumSegments(pActual, .tAseg)
	set tEn = ##class(DTL.Util.HL7).EnumSegments(pExpected, .tEseg)

	// Two empty messages are a perfect (if trivial) match.
	if (tEn = 0) && (tAn = 0) {
		set pStructScore = 1, pFieldScore = 1
		quit tArr
	}

	// --- structure score: matching segment-name skeleton ---
	set tStructMatch = 0, tStructTotal = $select(tEn>tAn:tEn, 1:tAn)
	if tStructTotal = 0 set tStructTotal = 1
	for i = 1:1:$select(tEn>tAn:tEn, 1:tAn) {
		set tAName = $get(tAseg(i, "name"), "")
		set tEName = $get(tEseg(i, "name"), "")
		if tAName = tEName, tAName '= "" set tStructMatch = tStructMatch + 1
	}
	set pStructScore = tStructMatch / tStructTotal

	// --- field score over EXPECTED-populated fields only ---
	// (create='new' produces sparse output; scoring over expected-populated
	//  leaves avoids flooding false MISSING diffs.)
	set tFieldTotal = 0, tFieldMatch = 0
	set tMax = $select(tEn>tAn:tEn, 1:tAn)
	for i = 1:1:tMax {
		set tAraw = $get(tAseg(i), "")
		set tEraw = $get(tEseg(i), "")
		set tSegName = $select($get(tEseg(i, "name"))'="":tEseg(i, "name"), 1:$get(tAseg(i, "name")))
		continue:tSegName=""
		set tIsMSH = (tSegName = "MSH")
		set tEfCount = ##class(DTL.Util.HL7).FieldCount(tEraw, tIsMSH)
		set tAfCount = ##class(DTL.Util.HL7).FieldCount(tAraw, tIsMSH)
		set tFmax = $select(tEfCount>tAfCount:tEfCount, 1:tAfCount)
		for f = $select(tIsMSH:3, 1:1):1:tFmax {
			set tEv = ##class(DTL.Util.HL7).FieldOf(tEraw, f, tIsMSH)
			set tAv = ##class(DTL.Util.HL7).FieldOf(tAraw, f, tIsMSH)
			// Only score positions the expected message populates.
			continue:tEv=""
			set tFieldTotal = tFieldTotal + 1
			if tEv = tAv {
				set tFieldMatch = tFieldMatch + 1
				continue
			}
			// Record a diff.
			set tD = {}
			set tD.SegName = tSegName
			set tD.Path = tSegName _ ":" _ f
			set tD.Kind = $select(tAv="":"MISSING", 1:"VALUE_MISMATCH")
			set tD.ExpectedValue = tEv
			set tD.ActualValue = tAv
			set tDerivable = (pSourceHL7 '= "") && (..ValueInSource(tEv, pSourceHL7))
			set tD.Severity = $select(tDerivable:"HIGH", pSourceHL7="":"MED", 1:"LOW")
			set tD.Hint = $select('tDerivable && (pSourceHL7'=""):"Expected value not found in source; likely illustrative — do not hard-code.", 1:"")
			do tArr.%Push(tD)
		}
	}
	set pFieldScore = $select(tFieldTotal=0:1, 1:tFieldMatch / tFieldTotal)
	quit tArr
}

/// True if pValue (or a component of it) appears anywhere in the source message.
ClassMethod ValueInSource(pValue As %String, pSourceHL7 As %String) As %Boolean
{
	quit:pValue="" 0
	set tSrc = ##class(DTL.Util.HL7).ToCR(pSourceHL7)
	quit (tSrc [ pValue)
}

/// One-shot: compile, run, compare. Returns a %DynamicObject with everything the
/// regeneration loop needs: compiled, compileErrors, ran, runErrors, className,
/// actual, matched, identical, score, structScore, fieldScore, diffCount, diffs.
ClassMethod VerifyAll(pSource As %String, pSourceHL7 As %String, pExpectedHL7 As %String, pSourceDocType As %String = "", pPolicy As %String = "CompileMatch", ByRef pClassName As %String = "", pThreshold As %Numeric = 0.85) As %DynamicObject
{
	set tRes = {}
	set tSC = ..CompileDTL(pSource, .pClassName, .tCompileErr)
	set tRes.className = pClassName
	set tRes.compiled = $$$ISOK(tSC)
	set tRes.compileErrors = tCompileErr
	if $$$ISERR(tSC) {
		set tRes.ran = 0, tRes.matched = 0, tRes.diffCount = "", tRes.score = 0
		quit tRes
	}
	set tSC = ..RunTransform(pClassName, pSourceHL7, pSourceDocType, .tActual, .tRunErr)
	set tRes.ran = $$$ISOK(tSC)
	set tRes.runErrors = tRunErr
	set tRes.actual = $get(tActual)
	if $$$ISERR(tSC) {
		set tRes.matched = 0, tRes.diffCount = "", tRes.score = 0
		quit tRes
	}
	set tCmp = ..Compare(tActual, pExpectedHL7, pPolicy, pThreshold, pSourceHL7)
	set tRes.matched = tCmp.matched
	set tRes.identical = tCmp.identical
	set tRes.score = tCmp.score
	set tRes.structScore = tCmp.structScore
	set tRes.fieldScore = tCmp.fieldScore
	set tRes.diffCount = tCmp.diffCount
	set tRes.diffs = tCmp.diffs
	set tRes.normalizedActual = tCmp.normalizedActual
	set tRes.normalizedExpected = tCmp.normalizedExpected
	quit tRes
}

/// ACCURACY GATE — run a compiled DTL over a SET of input messages and report,
/// per input: whether it ran, the produced output, and the set of (segment:field)
/// positions whose value CHANGED vs the input. A spec-driven transform that
/// compiles+runs but changes NOTHING (every assign silently swallowed by the DTL
/// try/catch on a bad path) is the classic silent-failure the old gate missed;
/// surfacing the changed-field set lets the caller verify the DTL is actually doing
/// work, and lets the LLM judge focus on conformance. Returns a %DynamicObject:
///   { ran:Bool, anyChange:Bool, results:[ {index, ran, error, output,
///       changedCount, changes:[ "SEG:field old -> new", ... ] } ] }
ClassMethod RunAll(pClassName As %String, ByRef pInputs, pSourceDocType As %String = "") As %DynamicObject
{
	set tRes = {}
	set tResults = []
	set tAllRan = 1, tAnyChange = 0
	set i = ""
	for {
		set i = $order(pInputs(i))
		quit:i=""
		set tIn = pInputs(i)
		continue:tIn=""
		set tRow = {}
		set tRow.index = i
		set tSC = ..RunTransform(pClassName, tIn, pSourceDocType, .tOut, .tErr)
		set tRow.ran = $$$ISOK(tSC)
		set tRow.error = $select($$$ISOK(tSC):"", 1:tErr)
		set tRow.output = $get(tOut)
		if $$$ISOK(tSC) {
			set tChanges = ..ChangedFields(tIn, $get(tOut))
			set tRow.changes = tChanges
			set tRow.changedCount = tChanges.%Size()
			if tChanges.%Size() > 0 set tAnyChange = 1
		} else {
			set tAllRan = 0
			set tRow.changes = []
			set tRow.changedCount = 0
		}
		do tResults.%Push(tRow)
	}
	set tRes.ran = tAllRan
	set tRes.anyChange = tAnyChange
	set tRes.results = tResults
	quit tRes
}

/// Compute the (segment:field) positions whose value differs between an input HL7
/// message and the transform's output. Used by the accuracy gate to prove the DTL
/// actually changed something (and to show the human exactly what it touched).
/// Returns a %DynamicArray of "SEG:field  [old] -> [new]" strings (capped).
ClassMethod ChangedFields(pInput As %String, pOutput As %String, pMax As %Integer = 60) As %DynamicArray
{
	set tArr = []
	set tI = ..Normalize(pInput, 1)     // neutralize volatile MSH-7/10 so a clock tick isn't a "change"
	set tO = ..Normalize(pOutput, 1)
	set tIn = ##class(DTL.Util.HL7).EnumSegments(tI, .tIseg)
	set tOn = ##class(DTL.Util.HL7).EnumSegments(tO, .tOseg)
	set tMax = $select(tOn>tIn:tOn, 1:tIn)
	for s = 1:1:tMax {
		set tIraw = $get(tIseg(s), "")
		set tOraw = $get(tOseg(s), "")
		set tSegName = $select($get(tOseg(s, "name"))'="":tOseg(s, "name"), 1:$get(tIseg(s, "name")))
		continue:tSegName=""
		continue:tIraw=tOraw         // identical segment -> nothing changed here
		set tIsMSH = (tSegName = "MSH")
		set tIfc = ##class(DTL.Util.HL7).FieldCount(tIraw, tIsMSH)
		set tOfc = ##class(DTL.Util.HL7).FieldCount(tOraw, tIsMSH)
		set tFmax = $select(tOfc>tIfc:tOfc, 1:tIfc)
		for f = $select(tIsMSH:3, 1:1):1:tFmax {
			set tIv = ##class(DTL.Util.HL7).FieldOf(tIraw, f, tIsMSH)
			set tOv = ##class(DTL.Util.HL7).FieldOf(tOraw, f, tIsMSH)
			continue:tIv=tOv
			do tArr.%Push(tSegName _ ":" _ f _ "  [" _ tIv _ "] -> [" _ tOv _ "]")
			if tArr.%Size() >= pMax return tArr
		}
	}
	quit tArr
}

/// Render a diffs array as a compact human-readable table for feedback/logging.
ClassMethod DiffsToText(pDiffs As %DynamicArray, pMax As %Integer = 25) As %String
{
	set tOut = "", tN = 0
	set it = pDiffs.%GetIterator()
	while it.%GetNext(.k, .d) {
		set tN = tN + 1
		quit:tN>pMax
		set tOut = tOut _ "  [" _ d.Severity _ "] " _ d.Path _ " | " _ d.Kind _ " | expected=[" _ d.ExpectedValue _ "] actual=[" _ d.ActualValue _ "]"
		if d.Hint '= "" set tOut = tOut _ "  (" _ d.Hint _ ")"
		set tOut = tOut _ $char(10)
	}
	if pDiffs.%Size() > pMax set tOut = tOut _ "  ... and " _ (pDiffs.%Size() - pMax) _ " more" _ $char(10)
	quit tOut
}

ClassMethod WrapTransform(pFragment As %String, pClassName As %String) As %String
{
	set nl = $char(10)
	set tCls = "Class " _ pClassName _ " Extends Ens.DataTransformDTL [ DependsOn = EnsLib.HL7.Message ]" _ nl
	set tCls = tCls _ "{" _ nl
	set tCls = tCls _ "XData DTL [ XMLNamespace = ""http://www.intersystems.com/dtl"" ]" _ nl
	set tCls = tCls _ "{" _ nl _ pFragment _ nl _ "}" _ nl _ "}" _ nl
	quit tCls
}

/// Sanitize a proposed class name so it is a legal IRIS class name. IRIS class
/// name segments must be alphanumeric (no underscores or other punctuation),
/// dots separate the package path. We strip illegal characters from each
/// segment, preserving the dotted package structure.
ClassMethod SanitizeClassName(pName As %String) As %String
{
	set tParts = $listfromstring(pName, ".")
	set tOut = "", ptr = 0
	while $listnext(tParts, ptr, tSeg) {
		// Keep only A-Z a-z 0-9 in each segment.
		set tClean = ""
		for i = 1:1:$length(tSeg) {
			set c = $extract(tSeg, i)
			if (c?1(1A,1N)) set tClean = tClean _ c
		}
		// A segment must start with a letter or %.
		if (tClean '= ""), '($extract(tClean)?1A) set tClean = "X" _ tClean
		continue:tClean=""
		set tOut = tOut _ $select(tOut'="":".", 1:"") _ tClean
	}
	if tOut = "" set tOut = "DTL.Generated.Candidate"
	quit tOut
}

ClassMethod ExtractClassName(pSource As %String, Output pName As %String) As %String
{
	set pName = ""
	set tLines = $listfromstring(pSource, $char(10))
	set ptr = 0
	while $listnext(tLines, ptr, tLine) {
		set tLineU = $zstrip(tLine, "<>W")
		if $extract($zconvert(tLineU, "U"), 1, 6) = "CLASS " {
			set tRest = $zstrip($extract(tLineU, 7, *), "<W")
			set pName = $piece(tRest, " ", 1)
			quit
		}
	}
	quit pName
}

}
