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
///   QUEUED -> PLANNING -> AWAITING_PLAN -(approve)-> GENERATING ->
///   AWAITING_ATTEMPT -(accept)-> SUCCESS | -(reject+feedback)-> GENERATING ...
/// Auto-approve jobs (file service / tests) go QUEUED -> RUNNING -> SUCCESS|FAILED.
Property Status As %String(VALUELIST = ",QUEUED,PLANNING,AWAITING_PLAN,RUNNING,GENERATING,AWAITING_ATTEMPT,SUCCESS,FAILED,REJECTED") [ InitialExpression = "QUEUED" ];

/// Final verdict from the orchestrator (SUCCESS, FAIL_COMPILE, ...).
Property Verdict As %String(MAXLEN = 32);

/// LLM-authored change plan (markdown) produced before any DTL is generated;
/// shown in the UI and approved by the user.
Property Plan As %String(MAXLEN = 32000);

/// Accumulating LLM conversation, persisted so each gated /continue step can
/// resume the dialogue without re-sending it from the client.
Property Transcript As list Of DTL.Msg.ChatTurn;

/// LLM provider for this job ("openai" | "mock"); needed to resume gated steps.
Property Provider As %String(MAXLEN = 16);

/// If this job is a refinement of an earlier one, the parent's JobId (lineage
/// for the History tab).
Property ParentJobId As %String(MAXLEN = 64);

/// User-supplied display name / input spec.
Property InputName As %String(MAXLEN = 256);

/// The input specification. Held as a STREAM, not a %String: an uploaded spec
/// document (PDF/DOCX→markdown) routinely exceeds the 32 000-char %String cap and
/// would otherwise raise "<value> length longer than MAXLEN allowed of 32000".
Property InputSpec As %Stream.GlobalCharacter;

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

/// Copy the persisted transcript into an LLMRequest's transcript list.
Method FillTranscript(pReq As DTL.Msg.LLMRequest)
{
	for i = 1:1:..Transcript.Count() {
		do pReq.Transcript.Insert(..Transcript.GetAt(i))
	}
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
	set o.createdAt = ..CreatedAt
	set o.updatedAt = ..UpdatedAt
	set o.attempts = []
	for i = 1:1:..Attempts.Count() {
		set a = ..Attempts.GetAt(i)
		do o.attempts.%Push(a.ToDynamic())
	}
	if pIncludeMessages {
		set o.inputSpec = ..StreamStr(..InputSpec)
		set o.sourceHL7 = ..StreamStr(..SourceHL7)
		set o.expectedHL7 = ..StreamStr(..ExpectedHL7)
		set o.actualHL7 = ..StreamStr(..ActualHL7)
		set o.finalDTL = ..StreamStr(..FinalDTL)
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
</Data>
<DataLocation>^DTL.Data.JobD</DataLocation>
<DefaultData>JobDefaultData</DefaultData>
<IdLocation>^DTL.Data.JobD</IdLocation>
<IndexLocation>^DTL.Data.JobI</IndexLocation>
<StreamLocation>^DTL.Data.JobS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
