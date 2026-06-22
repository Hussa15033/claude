/// Persistent record of a DTL-generation PROJECT — the top-level unit of work.
///
/// A project is created FIRST (before any specification), fixing the HL7 version for
/// the whole project. The user then attaches one or more specification documents to
/// it. Once the real work starts (specs locked), the attached specs are immutable: the
/// same per-document concise-spec + review workflow runs for each, and from the
/// approved specs the project derives the set of HL7 MESSAGE TYPES it covers. The user
/// picks which types to build DTLs for, and the project fans out one child
/// DTL.Data.Job per selected type — each the proven single-DTL pipeline, but seeded
/// with a per-type spec assembled from the approved concise specs. The project
/// aggregates their status, and at the end the generated DTLs can be saved as an IRIS
/// class package and/or exported as XML.
///
/// State machine:
///   DRAFT        — created; specs being attached + reviewed (specs editable here)
///   LOCKED       — user finished attaching; all specs approved; types being selected
///                  (specs are now immutable — "the real work has started")
///   GENERATING   — child jobs fanned out, building DTLs
///   REVIEW       — all child jobs have produced a candidate; human reviews each DTL
///   COMPLETE     — user accepted/exported the package
Class DTL.Data.Project Extends (%Persistent, %JSON.Adaptor)
{

/// Opaque public id (the REST resource id). Indexed for fast lookup.
Property Token As %String(MAXLEN = 64) [ Required ];

Index TokenIdx On Token [ Unique ];

/// Human-friendly project name.
Property Name As %String(MAXLEN = 256);

/// The HL7 version fixed for the WHOLE project at creation (e.g. "2.5", "2.5.1").
/// Every derived message type becomes "<HL7Version>:<structure>". Source = target for
/// now (in-version mapping); a separate target version is a future enhancement.
Property HL7Version As %String(MAXLEN = 16) [ Required ];

/// Lifecycle state — see class header.
Property Status As %String(VALUELIST = ",DRAFT,LOCKED,GENERATING,REVIEW,COMPLETE") [ InitialExpression = "DRAFT" ];

/// Ordered list of attached specification tokens (DTL.Data.SpecDoc.Token). Immutable
/// once Status>=LOCKED.
Property SpecTokens As list Of %String(MAXLEN = 64);

/// The message structures the user SELECTED to build (e.g. "ADT_A01","ORU_R01") — the
/// structure name only; the full DocType is HL7Version_":"_structure.
Property SelectedTypes As list Of %String(MAXLEN = 64);

/// Child job ids, one per selected type (parallel to SelectedTypes by build order).
Property JobIds As list Of %String(MAXLEN = 64);

/// LLM config captured at generation time (so every child job builds identically and
/// the UI can show what was used). The API key is NEVER stored — it's passed per
/// request and held transiently in ^DTL.ProjKey(token) for the build, like jobs do.
Property Provider As %String(MAXLEN = 16);

Property Model As %String(MAXLEN = 128);

/// Optional cheaper/faster model for the concise-spec calls (falls back to Model).
Property ConciseModel As %String(MAXLEN = 128);

/// Per-job cost ceiling (USD) propagated to each child job; 0 = no cap.
Property CostCap As %Numeric [ InitialExpression = 0 ];

/// Max repair attempts propagated to each child job.
Property MaxAttempts As %Integer [ InitialExpression = 5 ];

Property CreatedAt As %String(MAXLEN = 32);

Property UpdatedAt As %String(MAXLEN = 32);

ClassMethod OpenByToken(pToken As %String, Output pSC As %Status) As DTL.Data.Project
{
	set pSC = $$$OK
	quit ..TokenIdxOpen(pToken, , .pSC)
}

ClassMethod Now() As %String
{
	quit $zdatetime($ztimestamp, 3, 1)
}

/// True if the project's specs are still editable (only in DRAFT).
Method SpecsEditable() As %Boolean
{
	quit (..Status = "DRAFT")
}

/// Build a UI-friendly dynamic object. pDeep includes the per-spec review state and
/// the per-job summary (so the project detail screen renders in one call).
Method ToDynamic(pDeep As %Boolean = 1) As %DynamicObject
{
	set o = {}
	set o.token = ..Token
	set o.name = ..Name
	set o.hl7Version = ..HL7Version
	set o.status = ..Status
	set o.specsEditable = ..SpecsEditable()
	set o.provider = ..Provider
	set o.model = ..Model
	set o.conciseModel = ..ConciseModel
	set o.costCap = ..CostCap
	set o.maxAttempts = ..MaxAttempts
	set o.createdAt = ..CreatedAt
	set o.updatedAt = ..UpdatedAt
	// Headline stats (cost + counts + avg score) for BOTH the list card and the detail
	// page — cheap rollup from the ledger + child jobs; included even on the shallow
	// (pDeep=0) list call so cards can show cost without a second request.
	set o.stats = ..ComputeStats()
	set o.selectedTypes = []
	for i = 1:1:..SelectedTypes.Count() { do o.selectedTypes.%Push(..SelectedTypes.GetAt(i)) }
	// Per-spec review status (so the UI knows which specs still need approving).
	set o.specs = []
	for i = 1:1:..SpecTokens.Count() {
		set tTok = ..SpecTokens.GetAt(i)
		set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(tTok, .dsc)
		set s = {}
		set s.token = tTok
		if $isobject(tDoc) {
			set s.fileName = tDoc.FileName
			set s.status = tDoc.Status
			set s.conciseStatus = tDoc.ConciseStatus
			set s.conciseStarted = tDoc.ConciseStarted
			set s.conciseApproved = tDoc.ConciseApproved
			set s.confidence = tDoc.Confidence
			// Whether the original uploaded document is stored, so the UI can offer a
			// "download original" link on each spec (view-only access after lock).
			set s.hasOriginal = $select(tDoc.OrigBytes.Size > 0:1, 1:0)
		} else {
			set s.fileName = "(missing)", s.status = "ERROR", s.conciseApproved = 0, s.hasOriginal = 0
		}
		// Per-spec cost subtotal (generation + review), summed from the cost ledger.
		set sAgg = ##class(DTL.Util.Cost).ForRef(tTok)
		set s.cost = sAgg.cost, s.costByCategory = sAgg.byCategory
		do o.specs.%Push(s)
	}
	set o.allSpecsApproved = ..AllSpecsApproved()
	// Per-job summary (only meaningful once generating).
	set o.jobs = []
	if pDeep {
		for i = 1:1:..JobIds.Count() {
			set tJid = ..JobIds.GetAt(i)
			set tJob = ##class(DTL.Data.Job).OpenByJobId(tJid, .jsc)
			set j = {}
			set j.jobId = tJid
			set j.messageType = $select(i<=..SelectedTypes.Count():..SelectedTypes.GetAt(i), 1:"")
			if $isobject(tJob) {
				set j.status = tJob.Status
				set j.verdict = tJob.Verdict
				set j.sourceDocType = tJob.SourceDocType
				set j.finalScore = tJob.FinalScore
				set j.generatedClassName = tJob.GeneratedClassName
				set j.attemptsUsed = tJob.AttemptsUsed
			} else {
				set j.status = "MISSING"
			}
			// Per-DTL cost subtotal (plan + generate + judge), summed from the cost ledger.
			set jAgg = ##class(DTL.Util.Cost).ForRef(tJid)
			set j.cost = jAgg.cost, j.costByCategory = jAgg.byCategory
			do o.jobs.%Push(j)
		}
	}
	quit o
}

/// Headline stats for the project, shown on BOTH the projects-list card and the detail
/// page. Cost/tokens/calls come from the cost LEDGER (the sole authority) by summing
/// every spec token + job id; the rest are scanned from the child jobs. Returns
/// {totalCost, totalTokens, totalCalls, specsCount, specsApproved, dtlsTotal,
///  dtlsBuilt, dtlsFailed, avgScore} — avgScore is over jobs that produced a candidate.
Method ComputeStats() As %DynamicObject
{
	set s = {}
	set tCost = 0, tTok = 0, tCalls = 0
	// --- cost/tokens/calls from the ledger (spec rows + dtl rows) ---
	for i = 1:1:..SpecTokens.Count() {
		set a = ##class(DTL.Util.Cost).ForRef(..SpecTokens.GetAt(i))
		set tCost = tCost + a.cost, tTok = tTok + a.inTok + a.outTok, tCalls = tCalls + a.calls
	}
	for i = 1:1:..JobIds.Count() {
		set tJid = ..JobIds.GetAt(i)
		continue:tJid=""
		set a = ##class(DTL.Util.Cost).ForRef(tJid)
		set tCost = tCost + a.cost, tTok = tTok + a.inTok + a.outTok, tCalls = tCalls + a.calls
	}
	// --- spec counts ---
	set tSpecApproved = 0
	for i = 1:1:..SpecTokens.Count() {
		set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(..SpecTokens.GetAt(i), .dsc)
		if $isobject(tDoc), tDoc.ConciseApproved set tSpecApproved = tSpecApproved + 1
	}
	// --- dtl counts + average score (over jobs that produced a candidate) ---
	set tBuilt = 0, tFailed = 0, tScoreSum = 0, tScoreN = 0
	for i = 1:1:..JobIds.Count() {
		set tJid = ..JobIds.GetAt(i)
		continue:tJid=""
		set tJob = ##class(DTL.Data.Job).OpenByJobId(tJid, .jsc)
		continue:'$isobject(tJob)
		if (tJob.Status = "SUCCESS") || (tJob.Status = "AWAITING_ATTEMPT") set tBuilt = tBuilt + 1
		if tJob.Status = "FAILED" set tFailed = tFailed + 1
		if tJob.GeneratedClassName '= "" { set tScoreSum = tScoreSum + (+tJob.FinalScore), tScoreN = tScoreN + 1 }
	}
	set s.totalCost = tCost
	set s.totalTokens = tTok
	set s.totalCalls = tCalls
	set s.specsCount = ..SpecTokens.Count()
	set s.specsApproved = tSpecApproved
	set s.dtlsTotal = ..JobIds.Count()
	set s.dtlsBuilt = tBuilt
	set s.dtlsFailed = tFailed
	set s.avgScore = $select(tScoreN > 0: (tScoreSum / tScoreN), 1: "")
	quit s
}

/// True only if every attached spec has an APPROVED concise spec (the gate to LOCK).
Method AllSpecsApproved() As %Boolean
{
	quit:..SpecTokens.Count()=0 0
	set tOk = 1
	for i = 1:1:..SpecTokens.Count() {
		set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(..SpecTokens.GetAt(i), .dsc)
		if ('$isobject(tDoc)) || ('tDoc.ConciseApproved) set tOk = 0
	}
	quit tOk
}

Storage Default
{
<Data name="ProjectDefaultData">
<Value name="1">
<Value>%%CLASSNAME</Value>
</Value>
<Value name="2">
<Value>Token</Value>
</Value>
<Value name="3">
<Value>Name</Value>
</Value>
<Value name="4">
<Value>HL7Version</Value>
</Value>
<Value name="5">
<Value>Status</Value>
</Value>
<Value name="6">
<Value>SpecTokens</Value>
</Value>
<Value name="7">
<Value>SelectedTypes</Value>
</Value>
<Value name="8">
<Value>JobIds</Value>
</Value>
<Value name="9">
<Value>Provider</Value>
</Value>
<Value name="10">
<Value>Model</Value>
</Value>
<Value name="11">
<Value>ConciseModel</Value>
</Value>
<Value name="12">
<Value>CostCap</Value>
</Value>
<Value name="13">
<Value>MaxAttempts</Value>
</Value>
<Value name="14">
<Value>CreatedAt</Value>
</Value>
<Value name="15">
<Value>UpdatedAt</Value>
</Value>
</Data>
<DataLocation>^DTL.Data.ProjectD</DataLocation>
<DefaultData>ProjectDefaultData</DefaultData>
<IdLocation>^DTL.Data.ProjectD</IdLocation>
<IndexLocation>^DTL.Data.ProjectI</IndexLocation>
<StreamLocation>^DTL.Data.ProjectS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
