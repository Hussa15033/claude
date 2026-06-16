/// <class>DTL.Util.SampleGen</class> — SPEC-DRIVEN synthetic HL7 v2 input generator.
///
/// The whole point of this framework is that implementation partners rarely HAVE
/// sample messages — they work from a written spec. So the verification loop cannot
/// depend on the developer supplying input/output examples. This class manufactures
/// structurally-valid synthetic INPUT messages for a DocType straight from the
/// InterSystems-stored HL7 schema, so the generated DTL can be exercised, its output
/// schema-validated, and the whole thing round-tripped WITHOUT a single real sample.
///
/// It is deterministic (no Math.random — values are derived from indexes so a given
/// DocType+variant always yields the same message; reproducible bug reports) and
/// datatype-aware (it reads each field's HL7 datatype from the schema and emits a
/// plausible value: TS->timestamp, HD->components, CE->code^text, NM->number, …).
///
/// It produces a SET of variants, each exercising the DTL differently:
///   * MINIMAL  — required segments only, sparse fields (proves the DTL runs on a
///                bare-bones message).
///   * FULL     — required + optional segments, more fields populated (proves it
///                doesn't break on a rich message).
///   * SEEDED   — coded/ID/text fields seeded with values pulled from the spec
///                (rule trigger values like "F"/"M", facility codes) so CONDITIONAL
///                rules ("when PID-8 = F …") actually fire and get covered.
///
/// Same PPG-indirection walk as <class>DTL.Util.HL7Schema</class> (a ByRef local
/// array can't be name-indirected across method frames, but a process-private global
/// can), proven in the live container.
Class DTL.Util.SampleGen Extends %RegisteredObject
{

/// Generate up to pCount synthetic input messages for pDocType. Returns the number
/// produced; fills pMsgs(i) = HL7 string (CR-separated) and pMeta(i) = variant label.
/// pSeeds (optional %DynamicArray or ByRef array of strings) supplies spec-derived
/// values (codes, facilities, trigger values) to weave into the SEEDED variants so
/// conditional rules fire. Each produced message is import-checked; one that fails to
/// parse is dropped rather than returned (we never hand the loop an unusable input).
ClassMethod Generate(pDocType As %String, pCount As %Integer = 3, ByRef pSeeds, Output pMsgs, Output pMeta) As %Integer
{
	kill pMsgs, pMeta
	set tN = 0
	if pDocType = "" return 0
	// Normalise seeds into tSeed(1..k) — accept a %DynamicArray or a ByRef local array.
	kill tSeed  set tSeedN = 0
	if $isobject($get(pSeeds)) {
		set it = pSeeds.%GetIterator()
		while it.%GetNext(.k, .v) { set sv = $zstrip($select($isobject(v):"", 1:v), "<>W")  if sv'="" { set tSeedN = tSeedN + 1, tSeed(tSeedN) = sv } }
	} else {
		set sk = ""
		for { set sk = $order(pSeeds(sk))  quit:sk=""  set sv = $zstrip($get(pSeeds(sk)), "<>W")  if sv'="" { set tSeedN = tSeedN + 1, tSeed(tSeedN) = sv } }
	}

	kill ^||DTL.Gen
	try {
		do ##class(EnsLib.HL7.Schema).GetContentArray(.tC, "source", pDocType, , 0, 0)
		if $get(tC) = "" { kill ^||DTL.Gen  return 0 }
		merge ^||DTL.Gen = tC
		// Stash the message STRUCTURE (e.g. "SIU_S12") so BuildMSH can stamp a matching
		// MSH-9 type^trigger instead of a hardcoded ADT^A01.
		set ^||DTL.Gen("__struct") = $piece(pDocType, ":", 2)

		// Variant plan: (label, includeOptionalSegments, fieldDensity, useSeeds).
		set tPlan(1) = $listbuild("minimal", 0, 0)
		set tPlan(2) = $listbuild("full", 1, 0)
		set tPlan(3) = $listbuild("seeded", 0, 1)
		set tVer = $piece(pDocType, ":", 1)

		for v = 1:1:pCount {
			set tSpec = $get(tPlan(v))
			if tSpec = "" set tSpec = $listbuild("variant" _ v, (v#2), (v#2))   // beyond 3: alternate
			set tLabel = $list(tSpec, 1), tInclOpt = $list(tSpec, 2), tSeedIt = $list(tSpec, 3)
			// Build the ordered segment skeleton for this variant.
			kill tSegLines  set tSegN = 0
			do ..WalkSegs("", .tSegN, .tSegLines, tInclOpt, tVer, tSeedIt, .tSeed, tSeedN, v)
			// Assemble; force a correct MSH header up front (the walk emits a stub MSH).
			set tMsg = ""
			for s = 1:1:tSegN {
				set tLine = tSegLines(s)
				continue:tLine=""
				set tMsg = tMsg _ $select(tMsg'="":$char(13), 1:"") _ tLine
			}
			continue:tMsg=""
			// Import-check: only return messages that actually parse.
			set tChk = ##class(EnsLib.HL7.Message).ImportFromString(##class(DTL.Util.HL7).ToCR(tMsg), .isc)
			continue:'$$$ISOK(isc)
			set tN = tN + 1
			set pMsgs(tN) = ##class(DTL.Util.HL7).ToCR(tMsg)
			set pMeta(tN) = tLabel
		}
		kill ^||DTL.Gen
	} catch ex {
		kill ^||DTL.Gen
	}
	quit tN
}

/// Recursively walk the content tree, emitting one raw segment string per required
/// (and, when pInclOpt, optional) segment occurrence, in message order. pSegLines(n)
/// receives each assembled segment; pSegN is the running count. Repeating segments
/// are emitted once (the loop is about exercising the DTL, not cardinality fuzzing).
ClassMethod WalkSegs(pNode As %String, ByRef pSegN As %Integer, ByRef pSegLines, pInclOpt As %Boolean, pVer As %String, pSeedIt As %Boolean, ByRef pSeed, pSeedN As %Integer, pVariant As %Integer)
{
	set k = ""
	for {
		set k = ..NextNumChild(pNode, k)
		quit:k=""
		set tChildNode = $select(pNode="":k, 1:pNode _ "," _ k)
		set tName = ..Leaf(tChildNode, "name")
		set tType = ..Leaf(tChildNode, "type")
		set tOpt = ..Leaf(tChildNode, "opt")            // present (=1) on OPTIONAL nodes
		continue:tName=""
		set tIsSeg = ($extract(tType, 1, 3) = "SS:")
		set tIsGrp = (tType [ "grp")
		// Skip optional nodes unless this variant includes them.
		if 'pInclOpt, (tOpt '= "") continue
		if tIsSeg {
			set tCode = $translate($piece(tType, ":", 3), "()", "")   // SS:2.5:PID() -> PID
			continue:tCode=""
			set pSegN = pSegN + 1
			set pSegLines(pSegN) = ..BuildSegment(tChildNode, tCode, pVer, pSeedIt, .pSeed, pSeedN, pVariant)
		} elseif tIsGrp {
			do ..WalkSegs(tChildNode, .pSegN, .pSegLines, pInclOpt, pVer, pSeedIt, .pSeed, pSeedN, pVariant)
		}
	}
}

/// Build one raw segment string. MSH gets a correct, well-formed header. Every other
/// segment is populated field-by-field from its schema metadata with datatype-aware
/// synthetic values, up to a sensible cap so messages stay realistic.
ClassMethod BuildSegment(pNode As %String, pSegCode As %String, pVer As %String, pSeedIt As %Boolean, ByRef pSeed, pSeedN As %Integer, pVariant As %Integer) As %String
{
	if pSegCode = "MSH" quit ..BuildMSH(pNode, pVer, pVariant)
	// Discover the highest field subscript present for this segment.
	set tMaxF = ..MaxField(pNode)
	quit:tMaxF=0 pSegCode
	// Populate the meaningful leading fields. We don't fill EVERY field of a huge segment
	// (a 30-field PID would be noise) but we go well past the first handful so a segment
	// like SCH/RGS — whose useful fields sit mid-segment — is realistically populated.
	// Trailing fields left empty is valid HL7.
	set tCap = $select(tMaxF > 15:15, 1:tMaxF)
	set tSeg = pSegCode, f = 0, tSeedCur = 0
	for f = 1:1:tCap {
		set tFType = ..Leaf(pNode _ "," _ f, "type")          // DS:2.5:HD / DS:2.5:TS() / ""
		// Decide the value. On a SEEDED variant, occasionally inject a spec seed into a
		// codeable/text field so conditional rules can trigger.
		set tUseSeed = 0
		if pSeedIt, pSeedN > 0, ..Seedable(tFType) {
			set tSeedCur = tSeedCur + 1
			if tSeedCur <= pSeedN { set tUseSeed = 1, tSeedVal = pSeed((((tSeedCur - 1) # pSeedN) + 1)) }
		}
		set tVal = $select(tUseSeed:tSeedVal, 1:..FieldValue(pNode _ "," _ f, tFType, f, pVariant))
		set tSeg = tSeg _ "|" _ tVal
	}
	quit tSeg
}

/// A correct, well-formed MSH for the version, with non-empty required fields so the
/// message parses and DocType-derives cleanly. Trigger/structure are filled from the
/// schema's own MSH-9 default if available, else a generic event.
ClassMethod BuildMSH(pNode As %String, pVer As %String, pVariant As %Integer) As %String
{
	set tApp = "EPIC", tFac = "HOSP", tRApp = "RECVAPP", tRFac = "RECVFAC"
	set tDT = "20200101120000"
	// MSH-9 = code^trigger^structure, derived from the message STRUCTURE so the header
	// matches the message (e.g. SIU_S12 -> SIU^S12^SIU_S12), falling back to ADT^A01.
	set tStruct = $get(^||DTL.Gen("__struct"))
	set tMsgType = ..MshType(tStruct)
	set tCtrl = "MSG" _ (10000 + pVariant)
	set tVerId = $select(pVer'="":pVer, 1:"2.5")
	// MSH-1 '|' and MSH-2 '^~\&' are implicit in the layout below.
	quit "MSH|^~\&|" _ tApp _ "|" _ tFac _ "|" _ tRApp _ "|" _ tRFac _ "|" _ tDT _ "||" _ tMsgType _ "|" _ tCtrl _ "|P|" _ tVerId
}

/// Build the MSH-9 "code^trigger^structure" from a message structure name. "SIU_S12"
/// -> "SIU^S12^SIU_S12"; a structureless name -> "code^^". Falls back to ADT^A01.
ClassMethod MshType(pStruct As %String) As %String
{
	quit:pStruct="" "ADT^A01^ADT_A01"
	set tCode = $piece(pStruct, "_", 1)
	set tTrig = $piece(pStruct, "_", 2)
	quit tCode _ "^" _ tTrig _ "^" _ pStruct
}

/// Synthesise a REALISTIC value for a field, driven by BOTH its HL7 datatype (which
/// fixes the component shape) AND its schema field name (which biases the content) —
/// so a {XPN}:PatientName becomes "SMITH^JOHN^A", an {IS}:AdministrativeSex becomes
/// "M", a {TS}:DateTimeOfMessage becomes "20200101120000", a {CX}:PatientID becomes
/// "MRN100001^^^HOSP^MR". This is the difference between a useful sample message and a
/// row of "VAL1|VAL2|VAL3".
ClassMethod FieldValue(pNode As %String, pType As %String, pFieldNum As %Integer, pVariant As %Integer) As %String
{
	set tName = ..Leaf(pNode, "name")
	set tCode = $zconvert($translate($piece(pType, ":", 3), "()", ""), "U")
	// 1) A known COMPOSITE datatype -> its canonical, well-formed component shape.
	set tComp = ..Composite(tCode, tName, pFieldNum, pVariant)
	if tComp '= "" quit tComp
	// 2) An untemplated composite (has component subnodes) -> fill component 1 by its
	//    OWN datatype/name, so we still produce a sensible leaf rather than junk.
	if ..Leaf(pNode _ ",1", "name") '= "" {
		set tC1Type = $zconvert($translate($piece(..Leaf(pNode _ ",1", "type"), ":", 3), "()", ""), "U")
		set tC1Name = ..Leaf(pNode _ ",1", "name")
		quit ..NamedPrimitive($select(tC1Name'="":tC1Name, 1:tName), tC1Type, pFieldNum, pVariant)
	}
	// 3) Primitive leaf.
	quit ..NamedPrimitive(tName, tCode, pFieldNum, pVariant)
}

/// Build a canonical, realistic value for a known COMPOSITE HL7 datatype. Returns "" if
/// pCode is not a templated composite (the caller then handles it as a primitive). Only
/// the meaningful leading components are filled; the rest are left empty (valid HL7).
ClassMethod Composite(pCode As %String, pName As %String, pFieldNum As %Integer, pVariant As %Integer) As %String
{
	set v = pVariant
	if pCode = "XPN" quit ..Surname(v) _ "^" _ ..Given(v) _ "^A"                       // person name
	if pCode = "XCN" quit (1000 + pFieldNum) _ "^" _ ..Surname(v) _ "^" _ ..Given(v)   // id + name
	if pCode = "CX" quit "MRN" _ (100000 + pFieldNum + v) _ "^^^HOSP^MR"               // extended id
	if pCode = "CNN" quit (2000 + pFieldNum) _ "^" _ ..Surname(v) _ "^" _ ..Given(v)
	if pCode = "XON" quit "GENERAL HOSPITAL^^^^^^^^" _ (100 + v)                        // organization
	if pCode = "XAD" quit (100 + pFieldNum) _ " MAIN ST^^BOSTON^MA^02114^USA"           // address
	if pCode = "XTN" quit "(555)555-0" _ (100 + v)                                      // phone
	if pCode = "PL" quit "WARD" _ (1 + v) _ "^ROOM" _ pFieldNum _ "^A^HOSP"             // location
	if pCode = "EI" quit "EID" _ (1000 + pFieldNum + v)                                 // entity id
	if (pCode = "CE") || (pCode = "CWE") || (pCode = "CNE") quit ..CodeTriplet(pName, v)
	if (pCode = "TS") || (pCode = "DTM") || (pCode = "DR") || (pCode = "TQ") quit ..Stamp(v)
	if pCode = "CQ" quit (1 + v) _ "^min"                                               // quantity + units
	if pCode = "MSG" quit "ADT^A01"
	if pCode = "PT" quit "P"
	if pCode = "HD" quit ..HdValue(pName, v)                                            // hierarchic designator
	if pCode = "CP" quit "100.00^USD"                                                   // composite price
	quit ""
}

/// Primitive leaf value, biased by the field NAME first (a name that says "date"/"sex"/
/// "phone"/"id" wins), then by the datatype. Produces realistic, well-bounded values.
ClassMethod NamedPrimitive(pName As %String, pCode As %String, pFieldNum As %Integer, pVariant As %Integer) As %String
{
	set n = $zconvert(pName, "L"), v = pVariant
	// --- name-driven temporal/identity hints (override datatype) ---
	if (n [ "datetime") || ((n [ "date") && (n [ "time")) quit ..Stamp(v)
	if (pCode = "TS") || (pCode = "DTM") quit ..Stamp(v)
	if (pCode = "DT") quit "202001" _ ..Pad2(1 + (v # 28))
	if (pCode = "TM") quit "1200" _ ..Pad2(v # 60)
	if n [ "date" quit "202001" _ ..Pad2(1 + (v # 28))
	if n [ "time" quit "120000"
	if (n [ "sex") || (n [ "gender") quit $select(v # 2:"F", 1:"M")
	if (n [ "phone") || (n [ "telephone") quit "(555)555-0" _ (100 + v)
	if n [ "email" quit "patient" _ (v + 1) _ "@example.org"
	if (n [ "address") || (n [ "street") quit (100 + pFieldNum) _ " MAIN ST"
	if n [ "city" quit "BOSTON"
	if (n [ "state") || (n [ "province") quit "MA"
	if (n [ "zip") || (n [ "postal") quit "02114"
	if n [ "country" quit "USA"
	if (n [ "name") && (pCode '= "ID") && (pCode '= "IS") quit ..Surname(v)
	if n [ "facility" quit "001"
	if n [ "application" quit "EPIC"
	// --- datatype-driven ---
	if pCode = "SI" quit pFieldNum
	if pCode = "NM" quit (1 + pFieldNum + v)
	if pCode = "MO" quit "100.00"
	if (pCode = "ID") || (pCode = "IS") quit ..ShortCode(n, v)
	// numeric-ish identity fields
	if (n [ "number") || (n [ "seq") || ((n [ "id") && (n '[ "ident")) quit (1000 + pFieldNum + v)
	// --- free text (ST/TX/FT/unknown) ---
	quit ..ReadableText(pName, v)
}

/// True if a field is a reasonable target to inject a spec SEED value into (a code,
/// id, or free-text field) — we don't want to drop "F" into a timestamp field.
ClassMethod Seedable(pType As %String) As %Boolean
{
	set c = $zconvert($translate($piece(pType, ":", 3), "()", ""), "U")
	quit (c = "ID") || (c = "IS") || (c = "ST") || (c = "TX") || (c = "CE") || (c = "CWE") || (c = "CNE") || (c = "")
}

/// A coded-element triplet "code^text^system", biased by the field name where we can
/// recognise it, else a generic-but-valid active code.
ClassMethod CodeTriplet(pName As %String, pVariant As %Integer) As %String
{
	set n = $zconvert(pName, "L"), v = pVariant
	if (n [ "sex") || (n [ "gender") quit $select(v # 2:"F^Female^HL70001", 1:"M^Male^HL70001")
	if n [ "priority" quit "R^Routine^HL70027"
	if (n [ "reason") || (n [ "diagnos") quit "R51^Headache^I10"
	if n [ "language" quit "en^English^ISO639"
	if n [ "race" quit "2106-3^White^CDCREC"
	if (n [ "maritalstatus") || (n [ "marital") quit "M^Married^HL70002"
	quit $piece("AC^Active^L~RT^Routine^L~GN^General^L~ST^Standard^L", "~", (v # 4) + 1)
}

/// A short coded value for an ID/IS field, biased by name (sex, yes/no flags), else a
/// rotating single-letter code.
ClassMethod ShortCode(pNameLower As %String, pVariant As %Integer) As %String
{
	set n = pNameLower, v = pVariant
	if (n [ "sex") || (n [ "gender") quit $select(v # 2:"F", 1:"M")
	if (n [ "indicator") || (n [ "flag") || (n [ " y/n") quit $select(v # 2:"N", 1:"Y")
	if n [ "actioncode" quit $piece("A^U^D", "^", (v # 3) + 1)
	if n [ "class" quit $piece("I^O^E", "^", (v # 3) + 1)
	quit $piece("A^R^U^C^P", "^", (v # 5) + 1)
}

/// A clean, readable free-text value derived from the field name (self-documenting and
/// clearly synthetic), capped so it stays within realistic bounds. Falls back to "TEXT".
ClassMethod ReadableText(pName As %String, pVariant As %Integer) As %String
{
	set t = pName
	if $extract(t) = ":" set t = $extract(t, 2, *)              // strip the leading ":" the schema prefixes
	set t = $zstrip($translate(t, "()", "  "), "<>W")
	if t = "" set t = "TEXT"
	quit $extract(t, 1, 24)
}

/// Surname / given-name pools, indexed by variant so the synthetic messages differ.
ClassMethod Surname(pVariant As %Integer) As %String
{
	quit $piece("SMITH^JONES^BROWN^TAYLOR^WILSON", "^", (pVariant # 5) + 1)
}

ClassMethod Given(pVariant As %Integer) As %String
{
	quit $piece("JOHN^MARY^JAMES^PATRICIA^ROBERT", "^", (pVariant # 5) + 1)
}

/// A valid 14-digit HL7 timestamp, varied a little by variant.
ClassMethod Stamp(pVariant As %Integer) As %String
{
	quit "202001" _ ..Pad2(1 + (pVariant # 28)) _ "1200" _ ..Pad2(pVariant # 60)
}

/// A hierarchic-designator (namespace) value, name-biased.
ClassMethod HdValue(pName As %String, pVariant As %Integer) As %String
{
	set n = $zconvert(pName, "L")
	if n [ "application" quit "EPIC"
	if n [ "facility" quit "HOSP" _ (pVariant + 1)
	quit $piece("HOSP^LAB^RAD^CLINIC^PHARM", "^", (pVariant # 5) + 1)
}

/// Zero-pad an integer to 2 digits.
ClassMethod Pad2(pN As %Integer) As %String
{
	quit $select(pN < 10:"0" _ pN, 1:pN)
}

/// Highest numeric field subscript present under pNode (the segment's field count).
ClassMethod MaxField(pNode As %String) As %Integer
{
	set tMax = 0, f = ""
	for {
		set f = ..NextNumChild(pNode, f)
		quit:f=""
		if f = +f, f > tMax set tMax = f
	}
	quit tMax
}

// ---- PPG walk helpers (mirror DTL.Util.HL7Schema, operating on ^||DTL.Gen) ----

/// $order the next NUMERIC child subscript of pNode (skips metadata leaves).
ClassMethod NextNumChild(pNode As %String, pKey As %String) As %String
{
	set tQ = $select(pKey="":"""""", pKey=+pKey:pKey, 1:""""_pKey_"""")
	set tRef = $select(pNode="":"^||DTL.Gen(" _ tQ _ ")", 1:"^||DTL.Gen(" _ pNode _ "," _ tQ _ ")")
	set k = $order(@tRef)
	while (k '= "") && (k '= +k) {
		set tQ = $select(k="":"""""", k=+k:k, 1:""""_k_"""")
		set tRef = $select(pNode="":"^||DTL.Gen(" _ tQ _ ")", 1:"^||DTL.Gen(" _ pNode _ "," _ tQ _ ")")
		set k = $order(@tRef)
	}
	quit k
}

/// Read leaf ^||DTL.Gen(<node>, <leaf...>) via indirection. Accepts 1 or 2 leaf keys.
ClassMethod Leaf(pNode As %String, pLeaf As %String, pLeaf2 As %String = "") As %String
{
	set tQ1 = $select(pLeaf=+pLeaf:pLeaf, 1:""""_pLeaf_"""")
	if pLeaf2 = "" {
		set tRef = "^||DTL.Gen(" _ pNode _ "," _ tQ1 _ ")"
	} else {
		set tQ2 = $select(pLeaf2=+pLeaf2:pLeaf2, 1:""""_pLeaf2_"""")
		set tRef = "^||DTL.Gen(" _ pNode _ "," _ tQ1 _ "," _ tQ2 _ ")"
	}
	quit $get(@tRef)
}

}
