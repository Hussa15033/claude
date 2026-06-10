/// Persistent record of one DTL-generation job. It is the shared state between
/// the asynchronous forge process (the Orchestrator, which appends an entry per
/// attempt as it runs) and the REST layer (which polls it for live progress).
/// Serializes to a UI-friendly JSON document via ToJSON().
Class DTL.Data.Job Extends (%Persistent, %JSON.Adaptor)
{

/// Public job id (also the REST resource id). Indexed for fast lookup.
Property JobId As %String(MAXLEN = 64) [ Required ];

Index JobIdIdx On JobId [ Unique ];

/// Job state machine (drives the UI). With per-attempt approval enabled:
///   QUEUED -> STRUCTURING -> AWAITING_SPEC -(approve spec)-> PLANNING ->
///   AWAITING_PLAN -(approve)-> GENERATING -> AWAITING_ATTEMPT -(accept)->
///   SUCCESS | -(reject+feedback)-> GENERATING ...
/// The AWAITING_SPEC gate is the EARLIEST human checkpoint: the raw extracted
/// spec is restructured into an explicit, numbered rule list (with provenance back
/// to the original) and the human verifies it BEFORE any planning/DTL work, so an
/// extraction or interpretation error is caught before it propagates downstream.
/// Auto-approve jobs (file service / tests) go QUEUED -> RUNNING -> SUCCESS|FAILED.
Property Status As %String(VALUELIST = ",QUEUED,STRUCTURING,AWAITING_SPEC,PLANNING,AWAITING_PLAN,RUNNING,GENERATING,JUDGING,AWAITING_ATTEMPT,SUCCESS,FAILED,REJECTED") [ InitialExpression = "QUEUED" ];

/// Final verdict from the orchestrator (SUCCESS, FAIL_COMPILE, ...).
Property Verdict As %String(MAXLEN = 32);

/// LLM-authored change plan (markdown) produced before any DTL is generated;
/// shown in the UI and approved by the user.
Property Plan As %String(MAXLEN = 32000);

/// Accumulating LLM conversation, persisted so each gated /continue step can
/// resume the dialogue without re-sending it from the client.
Property Transcript As list Of DTL.Msg.ChatTurn;

/// 1-based index of the first turn belonging to the BUILD conversation (plan +
/// generation + repair). Turns before it are the one-off spec-structuring exchange
/// (which carries the large RAW spec) — kept for UI visibility but NOT re-sent to
/// the model on every build/repair call. FillTranscript only sends from here on,
/// so the expensive raw-spec text is billed once (during structuring), not N times.
Property BuildStartIndex As %Integer [ InitialExpression = 1 ];

/// LLM provider for this job ("openai" | "mock"); needed to resume gated steps.
Property Provider As %String(MAXLEN = 16);

/// If this job is a refinement of an earlier one, the parent's JobId (lineage
/// for the History tab).
Property ParentJobId As %String(MAXLEN = 64);

/// User-supplied display name / input spec.
Property InputName As %String(MAXLEN = 256);

/// The input specification (the RAW extracted markdown / typed text). Held as a
/// STREAM, not a %String: an uploaded spec document (PDF/DOCX→markdown) routinely
/// exceeds the 32 000-char %String cap and would otherwise raise "<value> length
/// longer than MAXLEN allowed of 32000".
Property InputSpec As %Stream.GlobalCharacter;

/// The STRUCTURED specification: the LLM rewrites the raw spec into an explicit,
/// numbered, unambiguous list of transformation rules (markdown). This is what the
/// human reviews/edits at the AWAITING_SPEC gate and what every downstream prompt
/// (plan, generation, repair, judge) is grounded on — NOT the raw extracted text.
/// Holding it as the authority means an extraction glitch is corrected once, here.
Property StructuredSpec As %Stream.GlobalCharacter;

/// Provenance map (JSON array) tying each structured rule back to the snippet of
/// the ORIGINAL spec it was derived from, so the review UI can show, side-by-side,
/// which part of the source each rule came from (and flag rules with NO source =
/// possible hallucination). Element: {rule, sourceQuote, ruleIndex, inferred}.
Property SpecProvenance As %Stream.GlobalCharacter;

/// The accuracy gate's machine verdict for the pending attempt (JSON): per-input
/// run results, rule-coverage findings, and the LLM-as-judge conformance opinion.
/// Surfaced in the UI so the human reviews an INFORMED candidate, not a blind one.
Property GateReport As %Stream.GlobalCharacter;

/// Running USD cost ceiling for this job. When the accumulated cost crosses it the
/// loop stops and pauses for the user (circuit-breaker) instead of burning budget.
/// 0 = no limit.
Property CostCap As %Numeric [ InitialExpression = 0 ];

/// Derived DocTypes for the primary pair.
Property SourceDocType As %String(MAXLEN = 64);

Property TargetDocType As %String(MAXLEN = 64);

/// Config knobs echoed back to the UI.
Property MaxAttempts As %Integer [ InitialExpression = 5 ];

Property SuccessPolicy As %String(MAXLEN = 32) [ InitialExpression = "CompileMatch" ];

/// LLM model used for this job (echoed back to the UI).
Property Model As %String(MAXLEN = 128);

/// Interoperability session id for this run — used to build the Visual Trace
/// deep-link. Set by the orchestrator at start.
Property SessionId As %String(MAXLEN = 32);

/// How many attempts have completed so far / final score / success flag.
Property AttemptsUsed As %Integer [ InitialExpression = 0 ];

Property FinalScore As %Numeric [ InitialExpression = 0 ];

Property Success As %Boolean [ InitialExpression = 0 ];

/// Per-attempt progress log (one Attempt object each), appended live.
Property Attempts As list Of DTL.Data.Attempt;

/// The primary pair's source + expected output (for the diff viewer).
Property SourceHL7 As %Stream.GlobalCharacter;

Property ExpectedHL7 As %Stream.GlobalCharacter;

/// transform(input) produced by the best DTL (for the diff viewer).
Property ActualHL7 As %Stream.GlobalCharacter;

/// Final (best) generated DTL class source.
Property FinalDTL As %Stream.GlobalCharacter;

Property GeneratedClassName As %String(MAXLEN = 220);

/// Human-readable field diff summary for the best candidate.
Property DiffSummary As %String(MAXLEN = 32000);

/// Last error (compile/runtime/LLM), if any.
Property LastError As %String(MAXLEN = 4000);

/// Timestamps (set by the caller; $ztimestamp-based strings).
Property CreatedAt As %String(MAXLEN = 32);

Property UpdatedAt As %String(MAXLEN = 32);

/// Append one attempt entry and bump UpdatedAt. Used by the orchestrator.
Method AddAttempt(pNumber As %Integer, pPhase As %String, pCompiled As %Boolean, pRan As %Boolean, pMatched As %Boolean, pScore As %Numeric, pMessage As %String = "") As %Status
{
	set a = ##class(DTL.Data.Attempt).%New()
	set a.Number = pNumber
	set a.Phase = pPhase
	set a.Compiled = pCompiled
	set a.Ran = pRan
	set a.Matched = pMatched
	set a.Score = pScore
	set a.Message = $extract(pMessage, 1, 4000)
	do ..Attempts.Insert(a)
	set ..AttemptsUsed = pNumber
	set ..UpdatedAt = ..Now()
	quit ..%Save()
}

/// Append a turn to the persisted conversation (system/user/assistant).
Method AddTurn(pRole As %String, pContent As %String)
{
	set t = ##class(DTL.Msg.ChatTurn).%New()
	set t.Role = pRole
	set t.Content = pContent
	do ..Transcript.Insert(t)
}

/// Copy the BUILD portion of the persisted transcript into an LLMRequest. The
/// one-off spec-structuring turns (indices before BuildStartIndex) carry the large
/// RAW spec and are deliberately omitted — the build conversation is grounded on
/// the compact STRUCTURED spec instead, so we don't re-bill the raw document on
/// every repair round. pFromBuild=0 forces the whole transcript (the structuring
/// call itself needs everything up to that point).
Method FillTranscript(pReq As DTL.Msg.LLMRequest, pFromBuild As %Boolean = 1)
{
	set tStart = $select(pFromBuild:$select(..BuildStartIndex>0:..BuildStartIndex, 1:1), 1:1)
	for i = tStart:1:..Transcript.Count() {
		set tTurn = ..Transcript.GetAt(i)
		continue:tTurn.Aux         // side calls (judge) are UI-only, never re-sent
		do pReq.Transcript.Insert(tTurn)
	}
}

/// Mark the most-recently-added turn as the cache breakpoint (the end of the
/// static, re-readable prefix) and record where the BUILD conversation begins
/// (the next turn appended after this one). Call right after adding the build
/// system prompt.
Method MarkBuildStart()
{
	set n = ..Transcript.Count()
	if n > 0 set ..Transcript.GetAt(n).CacheBreakpoint = 1
	set ..BuildStartIndex = n
}

/// The full LLM conversation as a %DynamicArray of {index, role, content} — every
/// message sent to and received from the model, in order, for the UI's
/// "LLM messages" view.
Method TranscriptDynamic() As %DynamicArray
{
	set arr = []
	for i = 1:1:..Transcript.Count() {
		set t = ..Transcript.GetAt(i)
		set o = {}
		set o.index = i
		set o.role = t.Role
		set o.content = t.Content
		set o.inputTokens = +t.InputTokens
		set o.outputTokens = +t.OutputTokens
		set o.cost = +t.Cost
		do arr.%Push(o)
	}
	quit arr
}

/// Token + cost totals for THIS job (summed over its assistant turns), plus the
/// running grand total across all jobs (kept in ^DTL.Usage). Returns a dynamic
/// object {inputTokens, outputTokens, totalTokens, cost, calls, model,
/// allTimeCost, allTimeTokens}.
Method UsageSummary() As %DynamicObject
{
	set tIn = 0, tOut = 0, tCost = 0, tCalls = 0
	for i = 1:1:..Transcript.Count() {
		set t = ..Transcript.GetAt(i)
		continue:t.Role'="assistant"
		set tIn = tIn + (+t.InputTokens), tOut = tOut + (+t.OutputTokens), tCost = tCost + (+t.Cost)
		if (+t.InputTokens) || (+t.OutputTokens) || (+t.Cost) set tCalls = tCalls + 1
	}
	set o = {}
	set o.inputTokens = tIn
	set o.outputTokens = tOut
	set o.totalTokens = tIn + tOut
	set o.cost = tCost
	set o.calls = tCalls
	set o.model = ..Model
	set o.allTimeCost = +$get(^DTL.Usage("cost"))
	set o.allTimeTokens = +$get(^DTL.Usage("tokens"))
	quit o
}

/// Convenience: load by public JobId.
ClassMethod OpenByJobId(pJobId As %String, Output pSC As %Status) As DTL.Data.Job
{
	set pSC = $$$OK
	quit ..JobIdIdxOpen(pJobId, , .pSC)
}

ClassMethod Now() As %String
{
	quit $zdatetime($ztimestamp, 3, 1)
}

/// Build a UI-friendly dynamic object for the REST layer.
Method ToDynamic(pIncludeMessages As %Boolean = 1) As %DynamicObject
{
	set o = {}
	set o.jobId = ..JobId
	set o.status = ..Status
	set o.verdict = ..Verdict
	set o.inputName = ..InputName
	set o.sourceDocType = ..SourceDocType
	set o.targetDocType = ..TargetDocType
	set o.maxAttempts = ..MaxAttempts
	set o.successPolicy = ..SuccessPolicy
	set o.attemptsUsed = ..AttemptsUsed
	set o.finalScore = ..FinalScore
	set o.success = ..Success
	set o.generatedClassName = ..GeneratedClassName
	set o.diffSummary = ..DiffSummary
	set o.lastError = ..LastError
	set o.model = ..Model
	set o.sessionId = ..SessionId
	set o.plan = ..Plan
	set o.parentJobId = ..ParentJobId
	set o.provider = ..Provider
	set o.costCap = ..CostCap
	set o.createdAt = ..CreatedAt
	set o.updatedAt = ..UpdatedAt
	set o.attempts = []
	for i = 1:1:..Attempts.Count() {
		set a = ..Attempts.GetAt(i)
		do o.attempts.%Push(a.ToDynamic())
	}
	if pIncludeMessages {
		set o.inputSpec = ..StreamStr(..InputSpec)
		set o.structuredSpec = ..StreamStr(..StructuredSpec)
		set o.sourceHL7 = ..StreamStr(..SourceHL7)
		set o.expectedHL7 = ..StreamStr(..ExpectedHL7)
		set o.actualHL7 = ..StreamStr(..ActualHL7)
		set o.finalDTL = ..StreamStr(..FinalDTL)
		// Provenance + gate report are JSON strings; parse so the UI gets objects,
		// not escaped strings. Tolerate empty/invalid by falling back to null.
		set o.specProvenance = ..ParseJSONOrNull(..StreamStr(..SpecProvenance))
		set o.gateReport = ..ParseJSONOrNull(..StreamStr(..GateReport))
	}
	quit o
}

ClassMethod StreamStr(pStream As %Stream.Object) As %String
{
	quit:'$isobject(pStream) ""
	do pStream.Rewind()
	set s = ""
	while 'pStream.AtEnd { set s = s _ pStream.Read(16000) }
	quit s
}

/// Parse a JSON string into a dynamic value for the REST layer; returns "" (JSON
/// null) if the string is empty or not valid JSON, so a half-written field can
/// never 500 the GET /jobs/:id endpoint.
ClassMethod ParseJSONOrNull(pStr As %String) As %DynamicAbstractObject
{
	quit:$zstrip($get(pStr), "<>W")="" ""
	try { return ##class(%DynamicAbstractObject).%FromJSON(pStr) } catch { return "" }
}

Storage Default
{
<Data name="JobDefaultData">
<Value name="1"><Value>%%CLASSNAME</Value></Value>
<Value name="2"><Value>JobId</Value></Value>
<Value name="3"><Value>Status</Value></Value>
<Value name="4"><Value>Verdict</Value></Value>
<Value name="5"><Value>InputName</Value></Value>
<Value name="7"><Value>SourceDocType</Value></Value>
<Value name="8"><Value>TargetDocType</Value></Value>
<Value name="9"><Value>MaxAttempts</Value></Value>
<Value name="10"><Value>SuccessPolicy</Value></Value>
<Value name="11"><Value>AttemptsUsed</Value></Value>
<Value name="12"><Value>FinalScore</Value></Value>
<Value name="13"><Value>Success</Value></Value>
<Value name="14"><Value>Attempts</Value></Value>
<Value name="15"><Value>SourceHL7</Value></Value>
<Value name="16"><Value>ExpectedHL7</Value></Value>
<Value name="17"><Value>ActualHL7</Value></Value>
<Value name="18"><Value>FinalDTL</Value></Value>
<Value name="19"><Value>GeneratedClassName</Value></Value>
<Value name="20"><Value>DiffSummary</Value></Value>
<Value name="21"><Value>LastError</Value></Value>
<Value name="22"><Value>CreatedAt</Value></Value>
<Value name="23"><Value>UpdatedAt</Value></Value>
<Value name="24"><Value>Model</Value></Value>
<Value name="25"><Value>SessionId</Value></Value>
<Value name="26"><Value>Plan</Value></Value>
<Value name="27"><Value>Transcript</Value></Value>
<Value name="28"><Value>Provider</Value></Value>
<Value name="29"><Value>ParentJobId</Value></Value>
<Value name="30"><Value>InputSpec</Value></Value>
<Value name="31"><Value>StructuredSpec</Value></Value>
<Value name="32"><Value>SpecProvenance</Value></Value>
<Value name="33"><Value>GateReport</Value></Value>
<Value name="34"><Value>CostCap</Value></Value>
<Value name="35"><Value>BuildStartIndex</Value></Value>
</Data>
<DataLocation>^DTL.Data.JobD</DataLocation>
<DefaultData>JobDefaultData</DefaultData>
<IdLocation>^DTL.Data.JobD</IdLocation>
<IndexLocation>^DTL.Data.JobI</IndexLocation>
<StreamLocation>^DTL.Data.JobS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
