/// Drives the GATED (per-attempt approval) DTL workflow as discrete, synchronous
/// steps, persisting all state on the DTL.Data.Job so each REST /continue call
/// advances exactly one step and the conversation survives across user think-time.
///
/// State machine (gated jobs):
///   PLANNING        -> (Plan step) -> AWAITING_PLAN
///   AWAITING_PLAN   -(approve)->     GENERATING -> AWAITING_ATTEMPT
///   AWAITING_ATTEMPT-(accept)->      SUCCESS
///   AWAITING_ATTEMPT-(reject,fb)->   GENERATING -> AWAITING_ATTEMPT (next attempt)
///
/// Each LLM call goes through a transient EnsLib.Testing.Service so it is fully
/// traced (the Job records the latest interop SessionId for the Visual Trace).
/// The auto-run (ungated) path still lives in DTL.Proc.Orchestrator.
Class DTL.Service.StepEngine Extends %RegisteredObject
{

Parameter LLMTARGET = "DTL.Op.LLMConnector";

/// Run the PLAN step for a freshly-created gated job: ask the LLM for a plan,
/// store it, and move the job to AWAITING_PLAN. Returns %Status.
ClassMethod Plan(pJob As DTL.Data.Job) As %Status
{
	set tSC = $$$OK
	try {
		set pJob.Status = "PLANNING"
		do pJob.%Save()
		// Spec-driven: the transformation is defined by the spec; inputs only.
		do pJob.AddTurn("system", ##class(DTL.Util.PromptBuilder).SystemPrompt())
		do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).SpecPlanPrompt(pJob.StreamStr(pJob.InputSpec), pJob.SourceDocType, ..InputsBlock(pJob)))
		set tReply = ..CallLLM(pJob, .tSession, .tErr, 1)
		if tReply = "" {
			set pJob.Status = "FAILED", pJob.LastError = "Planning LLM call failed: " _ tErr
			do pJob.%Save()
			quit
		}
		set pJob.SessionId = tSession
		set pJob.Plan = $extract(tReply, 1, 32000)
		do pJob.AddTurn("assistant", tReply)
		set pJob.Status = "AWAITING_PLAN"
		set pJob.UpdatedAt = ##class(DTL.Data.Job).Now()
		do pJob.%Save()
	} catch ex {
		set tSC = ex.AsStatus()
		set pJob.Status = "FAILED", pJob.LastError = ex.DisplayString()
		do pJob.%Save()
	}
	quit tSC
}

/// Approve the plan (or accept after a rejection) and run ONE generation attempt:
/// ask the LLM (transcript already primed), compile + run + verify, store the
/// candidate as the pending attempt, and move to AWAITING_ATTEMPT. On success
/// under the policy the job still pauses at AWAITING_ATTEMPT so the user can give
/// the final accept (consistent per-attempt gating).
ClassMethod GenerateOne(pJob As DTL.Data.Job) As %Status
{
	set tSC = $$$OK
	try {
		set tPrimary = pJob.StreamStr(pJob.SourceHL7)
		set tSpec = pJob.StreamStr(pJob.InputSpec)
		// Auto-repair loop: on COMPILE_FAIL / RUNTIME_FAIL feed the verbatim errors
		// back to the LLM and regenerate, recording each round as an attempt, until
		// it compiles+runs OR we hit MaxAttempts. The job only pauses for the user
		// (AWAITING_ATTEMPT) once it succeeds or the budget is exhausted.
		set tMax = $select(pJob.MaxAttempts>0:pJob.MaxAttempts, 1:5)
		set tFirstTurn = (pJob.AttemptsUsed = 0)
		for {
			set tAttempt = pJob.AttemptsUsed + 1
			set pJob.Status = "GENERATING"
			do pJob.%Save()
			set tClassName = "DTL.Generated." _ ..SafeName(pJob.InputName) _ "Job" _ ..SafeName(pJob.JobId) _ "A" _ tAttempt

			// Prime the conversation: the concrete "write the class" instruction on
			// the very first turn, the repair prompt on subsequent auto-repair rounds.
			if tFirstTurn {
				do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).SpecInitialPrompt(tSpec, pJob.SourceDocType, pJob.TargetDocType, tPrimary, tClassName))
				set tFirstTurn = 0
			}

			set tReply = ..CallLLM(pJob, .tSession, .tErr)
			set pJob.SessionId = tSession
			if tReply = "" {
				do pJob.AddAttempt(tAttempt, "LLM_ERROR", 0, 0, 0, 0, "LLM call failed: " _ tErr)
				set pJob.Status = "AWAITING_ATTEMPT", pJob.Verdict = "LLM_ERROR"
				set pJob.LastError = tErr
				do pJob.%Save()
				quit
			}

			// Extract + verify. Spec-driven: gate on COMPILE+RUN only (no expected diff).
			set tClassSrc = ##class(DTL.Util.Extractor).Extract(tReply, .tCN, .tValid)
			do pJob.AddTurn("assistant", tClassSrc)
			set tName = tClassName
			set tRes = ##class(DTL.Util.Verifier).VerifyAll(tClassSrc, tPrimary, tPrimary, pJob.SourceDocType, "CompileRun", .tName)

			set tPhase = $select('tRes.compiled:"COMPILE_FAIL", 'tRes.ran:"RUNTIME_FAIL", 1:"SUCCESS")
			set tNote = $case(tPhase,
				"COMPILE_FAIL":"Did not compile. " _ ..FirstLines(tRes.compileErrors, 4),
				"RUNTIME_FAIL":"Compiled, but failed at runtime: " _ ..FirstLines($get(tRes.runErrors), 3),
				:"Compiled & ran cleanly on the example input.")
			do pJob.AddAttempt(tAttempt, tPhase, tRes.compiled, tRes.ran, (tPhase="SUCCESS"), +tRes.score, tNote)

			// Stage this candidate (so the UI can show its DTL + output even mid-repair).
			set tActual = ""
			try { set tActual = tRes.actual } catch {}
			do pJob.FinalDTL.Clear()        do pJob.FinalDTL.Write(tClassSrc)
			do pJob.ActualHL7.Clear()       do pJob.ActualHL7.Write(tActual)
			set pJob.GeneratedClassName = tRes.className
			set pJob.DiffSummary = ""
			set pJob.FinalScore = +tRes.score
			set pJob.Verdict = $select(tPhase="SUCCESS":"SUCCESS", tPhase="COMPILE_FAIL":"FAIL_COMPILE", 1:"FAIL_RUNTIME")
			set pJob.LastError = $select(tPhase="SUCCESS":"", tPhase="COMPILE_FAIL":"Compile error: " _ ..FirstLines(tRes.compileErrors, 6), 1:"Runtime error: " _ ..FirstLines($get(tRes.runErrors), 4))
			do pJob.%Save()

			// Success, or out of budget -> pause for the user.
			if (tPhase = "SUCCESS") || (tAttempt >= tMax) quit

			// Otherwise auto-repair: feed the verbatim errors back and loop.
			if tPhase = "COMPILE_FAIL" {
				do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).CompileFixPrompt(tRes.compileErrors, pJob.SourceDocType, pJob.TargetDocType))
			} else {
				do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).RuntimeFixPrompt($get(tRes.runErrors), pJob.SourceDocType, pJob.TargetDocType))
			}
		}

		// Settle into AWAITING_ATTEMPT unless an LLM transport error already set state.
		if pJob.Status = "GENERATING" {
			set pJob.Status = "AWAITING_ATTEMPT"
			set pJob.UpdatedAt = ##class(DTL.Data.Job).Now()
			do pJob.%Save()
		}
	} catch ex {
		set tSC = ex.AsStatus()
		set pJob.Status = "FAILED", pJob.LastError = ex.DisplayString()
		do pJob.%Save()
	}
	quit tSC
}

/// First N non-empty lines of a multi-line error string, joined with " / " for a
/// compact one-line note (full text still goes to the LLM in the repair prompt).
ClassMethod FirstLines(pText As %String, pN As %Integer = 4) As %String
{
	set out = "", n = 0
	for i = 1:1:$length(pText, $char(10)) {
		set tLine = $zstrip($piece(pText, $char(10), i), "<>W")
		continue:tLine=""
		set out = out _ $select(out'="":" / ", 1:"") _ tLine
		set n = n + 1
		quit:n>=pN
	}
	quit $extract(out, 1, 3500)
}

/// User ACCEPTS the pending attempt: promote the DTL to a stable final class and
/// mark the job SUCCESS.
ClassMethod Accept(pJob As DTL.Data.Job) As %Status
{
	set tSC = $$$OK
	try {
		set tSrc = pJob.StreamStr(pJob.FinalDTL)
		if tSrc '= "" {
			set tName = ..SafeName(pJob.InputName) _ "Final"
			set sc = ##class(DTL.Util.Verifier).CompileDTL(tSrc, .tName)
			if $$$ISOK(sc) set pJob.GeneratedClassName = tName
		}
		set pJob.Status = "SUCCESS"
		set pJob.Success = 1
		set pJob.Verdict = "SUCCESS"
		set pJob.UpdatedAt = ##class(DTL.Data.Job).Now()
		do pJob.%Save()
		// Transform ALL example inputs with the accepted DTL for review.
		do ..TransformAll(pJob)
	} catch ex {
		set tSC = ex.AsStatus()
	}
	quit tSC
}

/// Run the job's final DTL over every stored input message and persist the
/// produced outputs in ^DTL.JobOutputs(jobId, n) = $lb(input, output, error).
ClassMethod TransformAll(pJob As DTL.Data.Job)
{
	kill ^DTL.JobOutputs(pJob.JobId)
	set tCls = pJob.GeneratedClassName
	quit:tCls=""
	set n = $order(^DTL.JobInputs(pJob.JobId, ""), -1)
	if n = "" {
		// at least the primary input
		set ^DTL.JobInputs(pJob.JobId, 1) = pJob.StreamStr(pJob.SourceHL7)
		set n = 1
	}
	for i = 1:1:n {
		set tIn = $get(^DTL.JobInputs(pJob.JobId, i))
		continue:tIn=""
		set sc = ##class(DTL.Util.Verifier).RunTransform(tCls, tIn, pJob.SourceDocType, .tOut, .tErr)
		set ^DTL.JobOutputs(pJob.JobId, i) = $listbuild(tIn, $get(tOut), $select($$$ISOK(sc):"", 1:tErr))
	}
}

/// Apply a correction: the reviewer gives a corrected output and/or feedback for a
/// specific input. Feed it back, regenerate the DTL, recompile/promote, and
/// re-transform all inputs. Leaves the job SUCCESS with the improved DTL.
ClassMethod Correct(pJob As DTL.Data.Job, pInput As %String, pProduced As %String, pCorrected As %String, pFeedback As %String) As %Status
{
	set tSC = $$$OK
	try {
		do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).CorrectionPrompt(pInput, pProduced, pCorrected, pFeedback))
		set tReply = ..CallLLM(pJob, .tSession, .tErr)
		set pJob.SessionId = tSession
		if tReply = "" { set pJob.LastError = "LLM correction failed: " _ tErr  do pJob.%Save()  quit }
		set tClassSrc = ##class(DTL.Util.Extractor).Extract(tReply, .tCN, .tValid)
		do pJob.AddTurn("assistant", tClassSrc)
		// Recompile under the stable final name and re-run the primary input.
		set tName = ..SafeName(pJob.InputName) _ "Final"
		set sc = ##class(DTL.Util.Verifier).CompileDTL(tClassSrc, .tName, .tCErr)
		if $$$ISERR(sc) { set pJob.LastError = "Correction did not compile: " _ tCErr  do pJob.%Save()  quit }
		do pJob.FinalDTL.Clear() do pJob.FinalDTL.Write(tClassSrc)
		set pJob.GeneratedClassName = tName
		set tAttempt = pJob.AttemptsUsed + 1
		do pJob.AddAttempt(tAttempt, "SUCCESS", 1, 1, 1, 1, "Applied correction/feedback and rebuilt the DTL.")
		set pJob.UpdatedAt = ##class(DTL.Data.Job).Now()
		do pJob.%Save()
		do ..TransformAll(pJob)
	} catch ex {
		set tSC = ex.AsStatus()
		set pJob.LastError = ex.DisplayString()  do pJob.%Save()
	}
	quit tSC
}

/// Build a labelled block of the example INPUT messages for a prompt.
ClassMethod InputsBlock(pJob As DTL.Data.Job) As %String
{
	set nl = $char(10), t = ""
	set n = $order(^DTL.JobInputs(pJob.JobId, ""), -1)
	if n = "" quit ##class(DTL.Util.PromptBuilder).PrettyHL7(pJob.StreamStr(pJob.SourceHL7))
	for i = 1:1:n {
		set tIn = $get(^DTL.JobInputs(pJob.JobId, i))
		continue:tIn=""
		set t = t _ nl _ "--- INPUT " _ i _ " ---" _ nl _ ##class(DTL.Util.PromptBuilder).PrettyHL7(tIn)
	}
	quit t
}

/// User REJECTS the pending attempt with feedback: append the feedback to the
/// conversation and run the next gated attempt (back to AWAITING_ATTEMPT).
ClassMethod Reject(pJob As DTL.Data.Job, pFeedback As %String) As %Status
{
	do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).RejectionPrompt(pFeedback))
	do pJob.%Save()
	quit ..GenerateOne(pJob)
}

/// Send the job's current transcript to the LLM via a transient, fully-traced
/// testing service. Returns the RAW assistant text ("" on failure) and the
/// session id. For a plan step the raw markdown is used as-is; for a generation
/// step the caller runs the Extractor over it to pull the class.
/// For the plan step pass pPlanMode=1 so a reply that is intentionally NOT a DTL
/// class (Ok=0 from the connector's class validator) is still accepted as text.
ClassMethod CallLLM(pJob As DTL.Data.Job, Output pSession As %String, Output pErr As %String, pPlanMode As %Boolean = 0) As %String
{
	set pSession = "", pErr = ""
	set sc = ##class(Ens.Director).CreateBusinessService("EnsLib.Testing.Service", .tSvc)
	if $$$ISERR(sc) { set pErr = $system.Status.GetErrorText(sc) quit "" }
	set tReq = ##class(DTL.Msg.LLMRequest).%New()
	set tReq.JobId = pJob.JobId
	set tReq.Attempt = pJob.AttemptsUsed + 1
	set tReq.Provider = pJob.Provider
	set tReq.Model = pJob.Model
	set tReq.ApiKey = $get(^DTL.JobKey(pJob.JobId))   // transient key, not on the Job record
	do pJob.FillTranscript(tReq)
	set sc = tSvc.SendRequestSync(..#LLMTARGET, tReq, .tResp, 120)
	set pSession = tSvc.%SessionId
	if $$$ISERR(sc) { set pErr = $system.Status.GetErrorText(sc) quit "" }
	if '$isobject(tResp) { set pErr = "no response" quit "" }
	// RawContent is always the assistant text; Ok=0 only means "no DTL class
	// extracted", which is expected for a plan reply.
	set tRaw = pJob.StreamStr(tResp.RawContent)
	if (tRaw = "") {
		// HTTP/transport problem (no content at all).
		set pErr = $select(tResp.ErrorText'="":tResp.ErrorText, 1:"empty response")
		quit ""
	}
	quit tRaw
}

ClassMethod SafeName(pName As %String) As %String
{
	set out = ""
	for i = 1:1:$length(pName) { set c = $extract(pName, i)  if (c?1(1A,1N)) set out = out _ c }
	if (out '= ""), '($extract(out)?1A) set out = "X" _ out
	quit $select(out'="":out, 1:"Job")
}

}
