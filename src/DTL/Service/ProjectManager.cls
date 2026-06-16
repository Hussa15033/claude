/// Orchestrates a PROJECT: the multi-specification, multi-message-type DTL build.
///
/// Lifecycle (mirrors DTL.Data.Project.Status):
///   Create        -> DRAFT  (fix HL7 version; attach + review specs)
///   AttachSpec     -> adds a SpecDoc token (only while DRAFT)
///   DeriveTypes    -> from the APPROVED concise specs, list the HL7 message types
///                     covered (appliesTo scopes + group types), resolved against the
///                     project's HL7 version
///   Generate       -> LOCK the specs, fan out one child DTL.Data.Job per SELECTED type,
///                     each seeded with a per-type spec ASSEMBLED from the approved
///                     concise specs (wildcard rules + rules scoped to that type)
///   (children build through the proven StepEngine pipeline, pausing at the per-DTL
///    review gate)
///   Export/Package -> XML export and/or list the compiled DTL.Generated.* package
///
/// Per-type spec assembly is the crux: a project spec covers many message types, but a
/// DTL is built for ONE. For each selected type we gather every approved item whose
/// appliesTo is "*" (generic/shared) OR names that type, and render a focused markdown
/// spec — so the child job's plan/generate/judge see only what's in scope.
Class DTL.Service.ProjectManager Extends %RegisteredObject
{

/// Create a project. pPayload: {name, hl7Version, provider, model, conciseModel,
/// costCap, maxAttempts}. Returns the new token via output.
ClassMethod Create(pPayload As %DynamicObject, Output pToken As %String, Output pSC As %Status) As %Status
{
	set pSC = $$$OK, pToken = ""
	try {
		set tVer = $zstrip(pPayload.hl7Version, "<>W")
		if tVer = "" { set pSC = $$$ERROR($$$GeneralError, "An HL7 version is required to create a project.")  quit }
		// Validate the version is installed.
		if '$data(^EnsHL7.Schema(tVer)) { set pSC = $$$ERROR($$$GeneralError, "HL7 version '" _ tVer _ "' is not installed in this instance.")  quit }
		set tPrj = ##class(DTL.Data.Project).%New()
		set tPrj.Token = ##class(DTL.Service.JobManager).RandHex()
		set tPrj.Name = $select(pPayload.name'="":pPayload.name, 1:"Project " _ tPrj.Token)
		set tPrj.HL7Version = tVer
		set tPrj.Status = "DRAFT"
		set tPrj.Provider = pPayload.provider
		set tPrj.Model = pPayload.model
		set tPrj.ConciseModel = pPayload.conciseModel
		set tPrj.CostCap = $select(pPayload.costCap'="":+pPayload.costCap, 1:0)
		set tPrj.MaxAttempts = $select(pPayload.maxAttempts'="":+pPayload.maxAttempts, 1:5)
		set tPrj.CreatedAt = ##class(DTL.Data.Project).Now()
		set tPrj.UpdatedAt = tPrj.CreatedAt
		set pSC = tPrj.%Save()
		quit:$$$ISERR(pSC)
		set pToken = tPrj.Token
	} catch ex { set pSC = ex.AsStatus() }
	quit pSC
}

/// Attach an (already-uploaded) spec document to the project. Only allowed while the
/// project is in DRAFT (before the real work starts). Idempotent.
ClassMethod AttachSpec(pProjectToken As %String, pSpecToken As %String, Output pSC As %Status) As %Status
{
	set pSC = $$$OK
	set tPrj = ##class(DTL.Data.Project).OpenByToken(pProjectToken, .sc)
	if '$isobject(tPrj) { set pSC = $$$ERROR($$$GeneralError, "No project '" _ pProjectToken _ "'")  quit pSC }
	if 'tPrj.SpecsEditable() { set pSC = $$$ERROR($$$GeneralError, "This project is locked — specifications can no longer be changed.")  quit pSC }
	set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pSpecToken, .dsc)
	if '$isobject(tDoc) { set pSC = $$$ERROR($$$GeneralError, "No specification '" _ pSpecToken _ "'")  quit pSC }
	// De-dupe.
	set tFound = 0
	for i = 1:1:tPrj.SpecTokens.Count() { if tPrj.SpecTokens.GetAt(i) = pSpecToken set tFound = 1 }
	if 'tFound do tPrj.SpecTokens.Insert(pSpecToken)
	set tPrj.UpdatedAt = ##class(DTL.Data.Project).Now()
	set pSC = tPrj.%Save()
	quit pSC
}

/// Detach a spec (DRAFT only).
ClassMethod DetachSpec(pProjectToken As %String, pSpecToken As %String, Output pSC As %Status) As %Status
{
	set pSC = $$$OK
	set tPrj = ##class(DTL.Data.Project).OpenByToken(pProjectToken, .sc)
	if '$isobject(tPrj) { set pSC = $$$ERROR($$$GeneralError, "No project")  quit pSC }
	if 'tPrj.SpecsEditable() { set pSC = $$$ERROR($$$GeneralError, "Project is locked.")  quit pSC }
	for i = tPrj.SpecTokens.Count():-1:1 { if tPrj.SpecTokens.GetAt(i) = pSpecToken do tPrj.SpecTokens.RemoveAt(i) }
	set tPrj.UpdatedAt = ##class(DTL.Data.Project).Now()
	set pSC = tPrj.%Save()
	quit pSC
}

/// Derive the set of HL7 MESSAGE TYPES the approved specs cover, resolved against the
/// project's HL7 version. Returns a %DynamicArray of {structure, docType, ruleCount,
/// fromWildcard} — structure is the schema structure name (e.g. "ADT_A01"), docType is
/// "<version>:<structure>". A type is included if some item's appliesTo names it (or a
/// group type does) AND it resolves to a real structure in this version. If every rule
/// is wildcard-only (no specific type), `types` is empty and `wildcardOnly` is true —
/// the UI then lets the user pick any DocType for the version.
ClassMethod DeriveTypes(pProjectToken As %String, Output pSC As %Status) As %DynamicObject
{
	set pSC = $$$OK, tRes = {}
	set tRes.types = [], tRes.wildcardOnly = 0
	set tPrj = ##class(DTL.Data.Project).OpenByToken(pProjectToken, .sc)
	if '$isobject(tPrj) { set pSC = $$$ERROR($$$GeneralError, "No project")  quit tRes }
	set tVer = tPrj.HL7Version
	// Accumulate counts per normalized structure, plus whether we saw any wildcard rule.
	kill tCount  set tAnyWild = 0, tAnySpecific = 0
	for i = 1:1:tPrj.SpecTokens.Count() {
		set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(tPrj.SpecTokens.GetAt(i), .dsc)
		continue:'$isobject(tDoc)
		continue:'tDoc.ConciseApproved
		set tProv = tDoc.ConciseProvStr()
		continue:tProv=""
		set tJson = ##class(DTL.Util.LLM).ParseJSON(tProv)
		continue:'$isobject(tJson)
		continue:'$isobject(tJson.groups)
		set git = tJson.groups.%GetIterator()
		while git.%GetNext(.gk, .g) {
			continue:'$isobject(g)
			// A group type may itself name a message type ("ADT^A01 / MSH").
			do ..HarvestType(g.type, tVer, .tCount, .tAnySpecific)
			continue:'$isobject(g.items)
			set iit = g.items.%GetIterator()
			while iit.%GetNext(.ik, .item) {
				continue:'$isobject(item)
				set tItemHadSpecific = 0
				if $isobject(item.appliesTo) {
					set ait = item.appliesTo.%GetIterator()
					while ait.%GetNext(.ak, .av) {
						set av = $zstrip($select($isobject(av):"", 1:av), "<>W")
						continue:av=""
						if av = "*" { set tAnyWild = 1  continue }
						do ..HarvestType(av, tVer, .tCount, .tHit)
						if $get(tHit) { set tItemHadSpecific = 1, tAnySpecific = 1 }
					}
				}
				if 'tItemHadSpecific set tAnyWild = 1
			}
		}
	}
	// Emit the resolved structures (sorted), with rule counts.
	set tStruct = ""
	for {
		set tStruct = $order(tCount(tStruct))
		quit:tStruct=""
		set o = {}
		set o.structure = tStruct
		set o.docType = tVer _ ":" _ tStruct
		set o.ruleCount = +tCount(tStruct)
		do tRes.types.%Push(o)
	}
	set tRes.wildcardOnly = ((tRes.types.%Size() = 0) && tAnyWild)
	set tRes.hl7Version = tVer
	quit tRes
}

/// Resolve a candidate message-type token (e.g. "ADT^A01", "ADT_A01", or a group type
/// like "ADT^A01 / MSH") to a real structure in pVer and, if valid, bump tCount. Sets
/// pHit=1 when it resolved to a real structure. Generic segment-only group types
/// ("MSH", "PID", "General") do NOT resolve and are ignored here.
ClassMethod HarvestType(pRaw As %String, pVer As %String, ByRef pCount, Output pHit)
{
	set pHit = 0
	set tRaw = $zstrip($get(pRaw), "<>W")
	quit:tRaw=""
	// Strip a "/segment" suffix from a group type ("ADT^A01 / MSH" -> "ADT^A01").
	if tRaw [ "/" set tRaw = $zstrip($piece(tRaw, "/", 1), "<>W")
	// Normalize type^trigger -> type_trigger (the schema structure form).
	set tStruct = $translate(tRaw, "^", "_")
	set tStruct = $translate(tStruct, " ", "")
	quit:tStruct=""
	// Must resolve to a real structure in this version.
	if $data(^EnsHL7.Schema(pVer, "MS", tStruct)) {
		set pCount(tStruct) = +$get(pCount(tStruct)) + 1
		set pHit = 1
	}
}

/// LOCK the project and fan out child jobs — one per selected message type. Each child
/// is the proven single-DTL pipeline, but seeded with a per-type ASSEMBLED spec and
/// driven straight through plan+generate (the project-level spec review already
/// happened). pSelected is a %DynamicArray (or $lb) of structure names. pApiKey/pRegion
/// are held transiently for the build. Returns the child job ids via the project.
ClassMethod Generate(pProjectToken As %String, pSelected As %DynamicArray, pApiKey As %String, pRegion As %String, Output pSC As %Status) As %Status
{
	set pSC = $$$OK
	set tPrj = ##class(DTL.Data.Project).OpenByToken(pProjectToken, .sc)
	if '$isobject(tPrj) { set pSC = $$$ERROR($$$GeneralError, "No project")  quit pSC }
	if (tPrj.Status '= "DRAFT") && (tPrj.Status '= "LOCKED") {
		set pSC = $$$ERROR($$$GeneralError, "Project already generating/complete (status " _ tPrj.Status _ ").")  quit pSC
	}
	if 'tPrj.AllSpecsApproved() { set pSC = $$$ERROR($$$GeneralError, "Every attached specification must be reviewed and approved before generating.")  quit pSC }
	// Collect the selected structures.
	kill tSel  set tNSel = 0
	if $isobject(pSelected) {
		set it = pSelected.%GetIterator()
		while it.%GetNext(.k, .v) { set sv = $zstrip($select($isobject(v):"", 1:v), "<>W")  if sv'="" { set tNSel = tNSel + 1, tSel(tNSel) = sv } }
	}
	if tNSel = 0 { set pSC = $$$ERROR($$$GeneralError, "Select at least one message type to generate.")  quit pSC }
	// Persist the API key transiently for the build.
	if pApiKey '= "" set ^DTL.ProjKey(pProjectToken) = pApiKey
	if pRegion '= "" set ^DTL.ProjRegion(pProjectToken) = pRegion
	// Lock + record selection.
	do tPrj.SelectedTypes.Clear()
	do tPrj.JobIds.Clear()
	set tPrj.Status = "GENERATING"
	set tPrj.UpdatedAt = ##class(DTL.Data.Project).Now()
	do tPrj.%Save()
	// Fan out: one child job per selected type.
	for s = 1:1:tNSel {
		set tStruct = tSel(s)
		do tPrj.SelectedTypes.Insert(tStruct)
		set tDocType = tPrj.HL7Version _ ":" _ tStruct
		// Assemble the per-type spec (markdown + filtered provenance JSON) from approved specs.
		set tAsm = ..AssembleSpecForType(tPrj, tStruct, .tProvJson)
		// Build the child job through JobManager (project mode: pre-approved spec, no
		// spec/plan gate — straight to generate, pausing at the per-DTL review).
		set tPayload = {}
		set tPayload.inputName = tPrj.Name _ " — " _ tStruct
		set tPayload.provider = tPrj.Provider
		set tPayload.model = tPrj.Model
		set tPayload.apiKey = pApiKey
		set tPayload.bedrockRegion = pRegion
		set tPayload.maxAttempts = tPrj.MaxAttempts
		set tPayload.costCap = tPrj.CostCap
		set tPayload.sourceDocType = tDocType
		set tPayload.targetDocType = tDocType
		set tPayload.projectToken = pProjectToken
		set tPayload.messageType = tStruct
		set tPayload.structuredSpec = tAsm
		set tPayload.specProvenance = $select($isobject(tProvJson):tProvJson.%ToJSON(), 1:"")
		set tSC = ##class(DTL.Service.JobManager).StartJob(tPayload, .tJid, .tStartSC)
		if $$$ISOK(tSC) && $$$ISOK(tStartSC) {
			do tPrj.JobIds.Insert(tJid)
		} else {
			// Record a placeholder so the project still shows the type with an error.
			do tPrj.JobIds.Insert("")
		}
	}
	set tPrj.UpdatedAt = ##class(DTL.Data.Project).Now()
	do tPrj.%Save()
	quit pSC
}

/// Assemble the focused specification for ONE message type from the project's APPROVED
/// concise specs. Includes every item whose appliesTo is "*" (generic) OR names this
/// type. Returns markdown; fills pProvJson (output) with a filtered provenance object
/// {title, groups:[{type,items:[...]}], ambiguities:[]} so the child job can still show
/// per-rule sources. pStruct is the structure name (e.g. "ADT_A01").
ClassMethod AssembleSpecForType(pPrj As DTL.Data.Project, pStruct As %String, Output pProvJson As %DynamicObject) As %String
{
	set nl = $char(10)
	set tWantHat = $translate(pStruct, "_", "^")        // appliesTo uses the ^ form
	set tWantUnd = pStruct                              // structure form
	set pProvJson = {}
	set pProvJson.title = pPrj.Name _ " — " _ pStruct _ " (" _ pPrj.HL7Version _ ")"
	set pProvJson.groups = []
	set pProvJson.ambiguities = []
	set tMd = "# " _ pProvJson.title _ nl _ nl
	set tMd = tMd _ "Transformation rules for HL7 " _ pPrj.HL7Version _ " " _ tWantHat _ " messages, assembled from the approved project specification(s)." _ nl _ nl
	set tAny = 0
	for i = 1:1:pPrj.SpecTokens.Count() {
		set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pPrj.SpecTokens.GetAt(i), .dsc)
		continue:'$isobject(tDoc)
		set tProv = tDoc.ConciseProvStr()
		continue:tProv=""
		set tJson = ##class(DTL.Util.LLM).ParseJSON(tProv)
		continue:'$isobject(tJson)
		continue:'$isobject(tJson.groups)
		set git = tJson.groups.%GetIterator()
		while git.%GetNext(.gk, .g) {
			continue:'$isobject(g)
			continue:'$isobject(g.items)
			// Collect in-scope items for this group.
			set tGroupMd = "", tGroupItems = []
			set iit = g.items.%GetIterator()
			while iit.%GetNext(.ik, .item) {
				continue:'$isobject(item)
				continue:'..ItemApplies(item, tWantHat, tWantUnd)
				set tGroupMd = tGroupMd _ "- " _ item.rule _ $select(''item.inferred:"  _(inferred)_", 1:"") _ nl
				// carry a filtered provenance item
				set pi = {}
				set pi.id = item.id, pi.rule = item.rule, pi.sourceQuote = item.sourceQuote, pi.inferred = ''item.inferred
				do tGroupItems.%Push(pi)
			}
			if tGroupItems.%Size() > 0 {
				set tAny = 1
				set tMd = tMd _ "## " _ $select(g.type'="":g.type, 1:"General") _ nl _ tGroupMd _ nl
				set pg = {}
				set pg.type = g.type, pg.items = tGroupItems
				do pProvJson.groups.%Push(pg)
			}
		}
	}
	if 'tAny set tMd = tMd _ "_(No specific rules found for this message type in the approved specifications; the generated DTL will be a faithful pass-through.)_" _ nl
	quit tMd
}

/// True if a concise item applies to the wanted message type: appliesTo contains "*"
/// (generic) or the wanted type in either ^ or _ form. An item with NO appliesTo is
/// treated as generic (applies to all), matching the concise-spec default.
ClassMethod ItemApplies(pItem As %DynamicObject, pWantHat As %String, pWantUnd As %String) As %Boolean
{
	if '$isobject(pItem.appliesTo) quit 1                  // no scope -> all types
	set tCount = 0, tMatch = 0
	set it = pItem.appliesTo.%GetIterator()
	while it.%GetNext(.k, .v) {
		set v = $zstrip($select($isobject(v):"", 1:v), "<>W")
		continue:v=""
		set tCount = tCount + 1
		if (v = "*") || ($translate(v, "^", "_") = pWantUnd) set tMatch = 1
	}
	if tCount = 0 quit 1                                   // empty array -> all types
	quit tMatch
}

/// Aggregate status roll-up + transition the project to REVIEW/COMPLETE as children
/// progress. Called by the REST status endpoint (cheap, idempotent).
ClassMethod RefreshStatus(pProjectToken As %String) As %Status
{
	set tPrj = ##class(DTL.Data.Project).OpenByToken(pProjectToken, .sc)
	quit:'$isobject(tPrj) $$$OK
	quit:(tPrj.Status'="GENERATING")&&(tPrj.Status'="REVIEW") $$$OK
	set tAll = 1, tAny = 0
	for i = 1:1:tPrj.JobIds.Count() {
		set tJid = tPrj.JobIds.GetAt(i)
		continue:tJid=""
		set tJob = ##class(DTL.Data.Job).OpenByJobId(tJid, .jsc)
		continue:'$isobject(tJob)
		set tAny = 1
		// A child is "settled" once it's awaiting human review or terminal.
		set tSettled = (tJob.Status="AWAITING_ATTEMPT")||(tJob.Status="SUCCESS")||(tJob.Status="FAILED")
		if 'tSettled set tAll = 0
	}
	if tAny, tAll, tPrj.Status = "GENERATING" {
		set tPrj.Status = "REVIEW"
		set tPrj.UpdatedAt = ##class(DTL.Data.Project).Now()
		do tPrj.%Save()
	}
	quit $$$OK
}

/// Export every FINAL DTL class in the project as a single XML string (the standard
/// IRIS class export, importable on any IRIS for Health). Returns "" if none built yet.
ClassMethod ExportXML(pProjectToken As %String, Output pSC As %Status) As %String
{
	set pSC = $$$OK
	set tPrj = ##class(DTL.Data.Project).OpenByToken(pProjectToken, .sc)
	if '$isobject(tPrj) { set pSC = $$$ERROR($$$GeneralError, "No project")  quit "" }
	kill tList  set tN = 0
	for i = 1:1:tPrj.JobIds.Count() {
		set tJid = tPrj.JobIds.GetAt(i)
		continue:tJid=""
		set tJob = ##class(DTL.Data.Job).OpenByJobId(tJid, .jsc)
		continue:'$isobject(tJob)
		continue:tJob.GeneratedClassName=""
		continue:'##class(%Dictionary.CompiledClass).%ExistsId(tJob.GeneratedClassName)
		set tList(tJob.GeneratedClassName _ ".CLS") = ""
		set tN = tN + 1
	}
	if tN = 0 { set pSC = $$$ERROR($$$GeneralError, "No generated DTL classes to export yet.")  quit "" }
	set tStream = ##class(%Stream.GlobalCharacter).%New()
	set pSC = $system.OBJ.ExportToStream(.tList, .tStream, "/displaylog=0")
	quit:$$$ISERR(pSC) ""
	do tStream.Rewind()
	set tOut = ""
	while 'tStream.AtEnd { set tOut = tOut _ tStream.Read(16000) }
	quit tOut
}

/// List the project's generated DTL classes (the "package"), with source. The classes
/// are already compiled DTL.Generated.* — "saving as a package" simply means they live
/// in the namespace; this returns them for display/confirmation + export.
ClassMethod PackageClasses(pProjectToken As %String) As %DynamicArray
{
	set arr = []
	set tPrj = ##class(DTL.Data.Project).OpenByToken(pProjectToken, .sc)
	quit:'$isobject(tPrj) arr
	for i = 1:1:tPrj.JobIds.Count() {
		set tJid = tPrj.JobIds.GetAt(i)
		continue:tJid=""
		set tJob = ##class(DTL.Data.Job).OpenByJobId(tJid, .jsc)
		continue:'$isobject(tJob)
		set o = {}
		set o.messageType = $select(i<=tPrj.SelectedTypes.Count():tPrj.SelectedTypes.GetAt(i), 1:"")
		set o.jobId = tJid
		set o.className = tJob.GeneratedClassName
		set o.status = tJob.Status
		set o.verdict = tJob.Verdict
		set o.exists = $select(tJob.GeneratedClassName'="":##class(%Dictionary.CompiledClass).%ExistsId(tJob.GeneratedClassName), 1:0)
		do arr.%Push(o)
	}
	quit arr
}

/// Mark the project COMPLETE (user accepted the package). Best-effort.
ClassMethod Complete(pProjectToken As %String, Output pSC As %Status) As %Status
{
	set pSC = $$$OK
	set tPrj = ##class(DTL.Data.Project).OpenByToken(pProjectToken, .sc)
	if '$isobject(tPrj) { set pSC = $$$ERROR($$$GeneralError, "No project")  quit pSC }
	set tPrj.Status = "COMPLETE"
	set tPrj.UpdatedAt = ##class(DTL.Data.Project).Now()
	set pSC = tPrj.%Save()
	quit pSC
}

/// List recent projects (newest first) for the projects landing screen.
ClassMethod ListProjects() As %DynamicArray
{
	set arr = []
	set tStmt = ##class(%SQL.Statement).%New()
	set sc = tStmt.%Prepare("SELECT Token FROM DTL_Data.Project ORDER BY ID DESC")
	if $$$ISOK(sc) {
		set rs = tStmt.%Execute()
		while rs.%Next() {
			set tPrj = ##class(DTL.Data.Project).OpenByToken(rs.%Get("Token"), .osc)
			continue:'$isobject(tPrj)
			do arr.%Push(tPrj.ToDynamic(0))
		}
	}
	quit arr
}

}
