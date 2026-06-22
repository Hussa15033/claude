/// The cost ledger's write + read API. EVERY LLM call in the product records its cost
/// here via Record(); every cost figure shown anywhere is computed here by summing
/// DTL.Data.CostEntry rows. Centralising both halves is what makes the numbers
/// reconcile: there is exactly one dollar formula (DTL.Util.Pricing.Cost) and one
/// place that maintains the account grand total (^DTL.Usage).
Class DTL.Util.Cost Extends %RegisteredObject
{

/// Record one LLM call. The dollar amount is computed HERE from the tokens (never
/// passed in), so it always matches the published pricing. Also bumps the account
/// grand total in ^DTL.Usage. Returns the row's USD cost (handy for cost-cap checks).
///
///   pCategory  spec.generate | spec.verify | dtl.plan | dtl.generate | dtl.judge
///   pRefKind   "spec" | "dtl"
///   pRefId     SpecDoc.Token (spec) or Job.JobId (dtl)
///   pLabel     timeline description, e.g. "Judging of DTL ADT_A01"
ClassMethod Record(pCategory As %String, pRefKind As %String, pRefId As %String, pLabel As %String, pModel As %String, pInTok As %Integer, pOutTok As %Integer) As %Numeric
{
	set tCost = ##class(DTL.Util.Pricing).Cost(pModel, +pInTok, +pOutTok)
	// Best-effort: a ledger write must never break the actual generation work, so any
	// failure here is swallowed (the call already happened and was billed regardless).
	try {
		set e = ##class(DTL.Data.CostEntry).%New()
		set e.Seq = $increment(^DTL.CostSeq)
		set e.Ts = $zdatetime($ztimestamp, 3, 1)
		set e.Category = pCategory
		set e.RefKind = pRefKind
		set e.RefId = pRefId
		set e.Label = pLabel
		set e.Model = pModel
		set e.InTok = +pInTok
		set e.OutTok = +pOutTok
		set e.Cost = tCost
		do e.%Save()
		// Account-wide running totals (now correctly include spec costs).
		set ^DTL.Usage("cost") = (+$get(^DTL.Usage("cost"))) + tCost
		set ^DTL.Usage("tokens") = (+$get(^DTL.Usage("tokens"))) + (+pInTok) + (+pOutTok)
	} catch ex {}
	quit tCost
}

/// Sum every ledger row for one ref (a spec token or a job id). Returns
/// {cost, inTok, outTok, calls, byCategory:{<cat>:{cost,inTok,outTok,calls}}}.
ClassMethod ForRef(pRefId As %String) As %DynamicObject
{
	set o = ..ZeroAgg()
	quit:pRefId="" o
	set tStmt = ##class(%SQL.Statement).%New()
	set sc = tStmt.%Prepare("SELECT Category,Cost,InTok,OutTok FROM DTL_Data.CostEntry WHERE RefId = ?")
	quit:$$$ISERR(sc) o
	set rs = tStmt.%Execute(pRefId)
	while rs.%Next() {
		do ..Accumulate(o, rs.%Get("Category"), +rs.%Get("Cost"), +rs.%Get("InTok"), +rs.%Get("OutTok"))
	}
	quit o
}

/// Full cost picture for a project: per-spec subtotals, per-DTL subtotals, the
/// complete chronological timeline (one labelled line per LLM call) and the totals.
/// Computed purely by enumerating the project's spec tokens + job ids and summing
/// their ledger rows, then unioning for the timeline — so perSpec + perDtl == total.
///
/// Returns {
///   projectToken, projectName,
///   perSpec:[{refId, fileName, cost, inTok, outTok, calls, byCategory}],
///   perDtl :[{refId(jobId), messageType, className, cost, inTok, outTok, calls, byCategory}],
///   timeline:[{seq, ts, category, refKind, refId, label, model, inTok, outTok, cost}],
///   specsTotal, dtlsTotal, projectTotal, grandTotal
/// }
ClassMethod ForProject(pProjectToken As %String) As %DynamicObject
{
	set o = {}
	set o.projectToken = pProjectToken
	set o.perSpec = [], o.perDtl = [], o.timeline = []
	set o.specsTotal = 0, o.dtlsTotal = 0, o.projectTotal = 0
	set o.grandTotal = +$get(^DTL.Usage("cost"))
	set tPrj = ##class(DTL.Data.Project).OpenByToken(pProjectToken, .sc)
	if '$isobject(tPrj) quit o
	set o.projectName = tPrj.Name
	// Collect the ids that belong to this project; ForRef-sum each; remember them so the
	// timeline below pulls exactly the same rows (guaranteeing perSpec+perDtl == timeline).
	kill tRef
	// --- per spec ---
	for i = 1:1:tPrj.SpecTokens.Count() {
		set tTok = tPrj.SpecTokens.GetAt(i)
		continue:tTok=""
		set tRef(tTok) = ""
		set tAgg = ..ForRef(tTok)
		set row = {}
		set row.refId = tTok
		set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(tTok, .dsc)
		set row.fileName = $select($isobject(tDoc):tDoc.FileName, 1:"(missing)")
		do ..CopyAgg(tAgg, row)
		do o.perSpec.%Push(row)
		set o.specsTotal = o.specsTotal + tAgg.cost
	}
	// --- per dtl ---
	for i = 1:1:tPrj.JobIds.Count() {
		set tJid = tPrj.JobIds.GetAt(i)
		continue:tJid=""
		set tRef(tJid) = ""
		set tAgg = ..ForRef(tJid)
		set row = {}
		set row.refId = tJid
		set row.messageType = $select(i<=tPrj.SelectedTypes.Count():tPrj.SelectedTypes.GetAt(i), 1:"")
		set tJob = ##class(DTL.Data.Job).OpenByJobId(tJid, .jsc)
		set row.className = $select($isobject(tJob):tJob.GeneratedClassName, 1:"")
		do ..CopyAgg(tAgg, row)
		do o.perDtl.%Push(row)
		set o.dtlsTotal = o.dtlsTotal + tAgg.cost
	}
	set o.projectTotal = o.specsTotal + o.dtlsTotal
	// --- timeline: every row whose RefId belongs to this project, in Seq order ---
	set tStmt = ##class(%SQL.Statement).%New()
	set sc = tStmt.%Prepare("SELECT Seq,Ts,Category,RefKind,RefId,Label,Model,InTok,OutTok,Cost FROM DTL_Data.CostEntry ORDER BY Seq")
	if $$$ISOK(sc) {
		set rs = tStmt.%Execute()
		while rs.%Next() {
			set tId = rs.%Get("RefId")
			continue:'$data(tRef(tId))
			set t = {}
			set t.seq = +rs.%Get("Seq")
			set t.ts = rs.%Get("Ts")
			set t.category = rs.%Get("Category")
			set t.refKind = rs.%Get("RefKind")
			set t.refId = tId
			set t.label = rs.%Get("Label")
			set t.model = rs.%Get("Model")
			set t.inTok = +rs.%Get("InTok")
			set t.outTok = +rs.%Get("OutTok")
			set t.cost = +rs.%Get("Cost")
			do o.timeline.%Push(t)
		}
	}
	quit o
}

/// Account-wide totals (every project + any orphaned rows).
ClassMethod Grand() As %DynamicObject
{
	set o = {}
	set o.cost = +$get(^DTL.Usage("cost"))
	set o.tokens = +$get(^DTL.Usage("tokens"))
	quit o
}

/// --- small helpers (keep the aggregate shape in one place) ---
ClassMethod ZeroAgg() As %DynamicObject
{
	set o = {}
	set o.cost = 0, o.inTok = 0, o.outTok = 0, o.calls = 0
	set o.byCategory = {}
	quit o
}

ClassMethod Accumulate(pAgg As %DynamicObject, pCat As %String, pCost As %Numeric, pIn As %Integer, pOut As %Integer)
{
	set pAgg.cost = pAgg.cost + pCost
	set pAgg.inTok = pAgg.inTok + pIn
	set pAgg.outTok = pAgg.outTok + pOut
	set pAgg.calls = pAgg.calls + 1
	set c = pAgg.byCategory.%Get(pCat)
	if '$isobject(c) { set c = {}  set c.cost = 0, c.inTok = 0, c.outTok = 0, c.calls = 0  do pAgg.byCategory.%Set(pCat, c) }
	set c.cost = c.cost + pCost
	set c.inTok = c.inTok + pIn
	set c.outTok = c.outTok + pOut
	set c.calls = c.calls + 1
}

/// Copy the four scalars + byCategory from an aggregate onto a result row.
ClassMethod CopyAgg(pAgg As %DynamicObject, pRow As %DynamicObject)
{
	set pRow.cost = pAgg.cost
	set pRow.inTok = pAgg.inTok
	set pRow.outTok = pAgg.outTok
	set pRow.calls = pAgg.calls
	set pRow.byCategory = pAgg.byCategory
}

}
