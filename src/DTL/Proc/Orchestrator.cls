/// The orchestration Business Process: the GenAI DTL regeneration loop.
///
/// On receiving a <class>DTL.Msg.ForgeRequest</class> (one input/output HL7v2
/// example pair) it:
///   1. builds the system + initial-user prompt,
///   2. calls the LLM operation synchronously to get a DTL class,
///   3. compiles it (capturing line-numbered errors),
///   4. runs the transform against the input message,
///   5. verifies the output against the expected output under the success policy,
///   6. on failure, feeds the compile errors / runtime error / field diff back as
///      the next user turn and regenerates,
/// looping up to MaxAttempts or until the policy is satisfied. It always returns
/// the best compiling+running candidate found, with its diff.
///
/// Implemented as a plain Ens.BusinessProcess in ObjectScript (not BPL): the loop
/// state lives in persistent process properties so it survives the dehydration
/// that occurs across each synchronous call.
Class DTL.Proc.Orchestrator Extends Ens.BusinessProcess
{

/// Config name of the LLM business operation to call.
Property LLMTarget As %String [ InitialExpression = "DTL.Op.LLMConnector" ];

/// Timeout (seconds) for each synchronous LLM call.
Property LLMTimeout As %Integer [ InitialExpression = 120 ];

/// Where to write result artifacts (winning .cls + result json). Blank = skip.
Property ArtifactDir As %String;

Parameter SETTINGS = "LLMTarget:Basic,LLMTimeout:Basic,ArtifactDir:Basic";

// ---- persistent loop state (survives SendRequestSync dehydration) ----
Property JobId As %String [ Internal ];
Property Attempt As %Integer [ Internal ];
Property BestScore As %Numeric [ Internal, InitialExpression = -1 ];
Property BestClassName As %String [ Internal ];
Property BestDTL As %Stream.GlobalCharacter [ Internal ];
Property BestActual As %Stream.GlobalCharacter [ Internal ];
Property BestDiffText As %String(MAXLEN = 32000) [ Internal ];
Property LastScore As %Numeric [ Internal, InitialExpression = -1 ];
Property PlateauCount As %Integer [ Internal, InitialExpression = 0 ];
Property Transcript As list Of DTL.Msg.ChatTurn [ Internal ];
Property SeenHashes As %String(MAXLEN = 32000) [ Internal ];
Property Request As DTL.Msg.ForgeRequest [ Internal ];
Property FinalVerdict As %String [ Internal ];

/// Entry point: drive the whole loop synchronously and return a ForgeResponse.
Method OnRequest(pRequest As DTL.Msg.ForgeRequest, Output pResponse As Ens.Response) As %Status
{
	set tSC = $$$OK
	try {
		set ..Request = pRequest
		set ..JobId = $select(pRequest.JobId'="":pRequest.JobId, 1:$zhex($random(2147483647)))
		set ..Attempt = 0
		set ..BestScore = -1
		set ..PlateauCount = 0
		set ..SeenHashes = ""

		set tSrcHL7 = ..StreamToString(pRequest.SourceHL7)
		set tTgtHL7 = ..StreamToString(pRequest.TargetHL7)
		set tSrcDoc = pRequest.SourceDocType
		set tTgtDoc = pRequest.TargetDocType
		set tClassName = "DTL.Generated." _ ..SafeName(pRequest.InputName) _ "Job" _ ..SafeName(..JobId)

		// Mark the linked Job record RUNNING and record this run's session id so the
		// UI can deep-link to the Visual Trace for the whole conversation.
		do ..JobStart(..%SessionId)

		// Seed the transcript: system + initial user prompt (incl. spec + extra pairs).
		do ..AddTurn("system", ##class(DTL.Util.PromptBuilder).SystemPrompt())
		do ..AddTurn("user", ##class(DTL.Util.PromptBuilder).InitialUserPrompt(tSrcHL7, tTgtHL7, tSrcDoc, tTgtDoc, ..BuildInstructions(pRequest), tClassName))

		set tMax = $select(pRequest.MaxAttempts>0:pRequest.MaxAttempts, 1:5)
		set tPolicy = $select(pRequest.SuccessPolicy'="":pRequest.SuccessPolicy, 1:"CompileMatch")
		set tThreshold = $select(pRequest.MatchThreshold>0:pRequest.MatchThreshold, 1:0.85)
		set tSuccess = 0

		for tAttempt = 1:1:tMax {
			set ..Attempt = tAttempt
			$$$LOGINFO("DTL forge "_..JobId_": attempt "_tAttempt_"/"_tMax)

			// --- 1. Call the LLM synchronously ---
			set tLLMReq = ##class(DTL.Msg.LLMRequest).%New()
			set tLLMReq.JobId = ..JobId
			set tLLMReq.Attempt = tAttempt
			set tLLMReq.Provider = pRequest.Provider
			set tLLMReq.Model = pRequest.Model
			set tLLMReq.ApiKey = pRequest.ApiKey
			for i = 1:1:..Transcript.Count() {
				do tLLMReq.Transcript.Insert(..Transcript.GetAt(i))
			}
			set tSC = ..SendRequestSync(..LLMTarget, tLLMReq, .tLLMResp, ..LLMTimeout)
			if $$$ISERR(tSC) {
				$$$LOGWARNING("LLM call failed: "_$system.Status.GetErrorText(tSC))
				set ..FinalVerdict = "LLM_ERROR"
				do ..JobAttempt(tAttempt, "LLM_ERROR", 0, 0, 0, 0, "LLM transport error: "_$system.Status.GetErrorText(tSC))
				continue
			}
			if '$isobject(tLLMResp) || 'tLLMResp.Ok {
				set tErr = $select($isobject(tLLMResp):tLLMResp.ErrorText, 1:"no response")
				$$$LOGWARNING("LLM unusable reply: "_tErr)
				set ..FinalVerdict = "LLM_ERROR"
				do ..JobAttempt(tAttempt, "LLM_ERROR", 0, 0, 0, 0, "Unusable LLM reply: "_tErr)
				// Feed a corrective instruction and retry.
				do ..AddTurn("user", "Your previous reply did not contain a valid DTL class. Output ONLY a complete class named '"_tClassName_"' as specified.")
				continue
			}

			set tCandidate = ..StreamToString(tLLMResp.ExtractedClass)
			// Record the assistant turn (the cleaned class) for the transcript.
			do ..AddTurn("assistant", tCandidate)

			// --- cycle guard: identical candidate seen before? ---
			set tHash = $zcrc(tCandidate, 7)
			if ..SeenHashes [ ("|"_tHash_"|") {
				$$$LOGINFO("Identical candidate repeated; stopping (unsatisfiable).")
				set ..FinalVerdict = "UNSATISFIABLE"
				quit
			}
			set ..SeenHashes = ..SeenHashes _ "|" _ tHash _ "|"

			// --- 2-5. Compile + run + verify ---
			set tAttClass = tClassName _ "A" _ tAttempt
			set tRes = ##class(DTL.Util.Verifier).VerifyAll(tCandidate, tSrcHL7, tTgtHL7, tSrcDoc, tPolicy, .tAttClass, tThreshold)

			set tScore = +tRes.score
			set tDiffText = $select(tRes.diffCount'="" && (tRes.diffCount>0):##class(DTL.Util.Verifier).DiffsToText(tRes.diffs, 25), 1:"")

			// Track best compiling+running candidate.
			if (tRes.compiled && tRes.ran) {
				if (tScore > ..BestScore) {
					set ..BestScore = tScore
					set ..BestClassName = tRes.className
					do ..SetStream(..BestDTL, tCandidate)
					do ..SetStream(..BestActual, tRes.actual)
					set ..BestDiffText = tDiffText
				}
			}

			$$$LOGINFO("attempt "_tAttempt_": compiled="_tRes.compiled_" ran="_tRes.ran_" matched="_tRes.matched_" score="_$fnumber(tScore,"",3))

			// --- 6. success / failure decision ---
			if (tRes.matched) {
				set tSuccess = 1
				set ..FinalVerdict = "SUCCESS"
				set ..BestClassName = tRes.className
				do ..SetStream(..BestDTL, tCandidate)
				do ..SetStream(..BestActual, tRes.actual)
				set ..BestScore = tScore
				set ..BestDiffText = tDiffText
				do ..JobAttempt(tAttempt, "SUCCESS", tRes.compiled, tRes.ran, 1, tScore, "Output matches expected (score "_$fnumber(tScore,"",3)_").")
				quit
			}

			// Determine verdict for feedback + plateau detection.
			if 'tRes.compiled { set ..FinalVerdict = "FAIL_COMPILE" }
			elseif 'tRes.ran { set ..FinalVerdict = "FAIL_RUNTIME" }
			else { set ..FinalVerdict = "FAIL_MATCH" }

			// Record this attempt's outcome live for the UI.
			set tPhase = $case(..FinalVerdict, "FAIL_COMPILE":"COMPILE_FAIL", "FAIL_RUNTIME":"RUNTIME_FAIL", :"MISMATCH")
			set tNote = $case(tPhase, "COMPILE_FAIL":$piece(tRes.compileErrors,$char(10),1), "RUNTIME_FAIL":$get(tRes.runErrors), :(tRes.diffCount_" field difference(s); score "_$fnumber(tScore,"",3)))
			do ..JobAttempt(tAttempt, tPhase, tRes.compiled, tRes.ran, 0, tScore, tNote)

			// Plateau guard: no score improvement for 2 consecutive attempts.
			if (tRes.compiled && tRes.ran) {
				if (..LastScore >= 0) && ($zabs(tScore - ..LastScore) < 0.001) {
					set ..PlateauCount = ..PlateauCount + 1
				} else {
					set ..PlateauCount = 0
				}
				set ..LastScore = tScore
				if (..PlateauCount >= 2) {
					$$$LOGINFO("Score plateaued; stopping (likely non-literal pair).")
					set ..FinalVerdict = "UNSATISFIABLE"
					quit
				}
			}

			// Build feedback for the next attempt (unless this was the last).
			if tAttempt < tMax {
				do ..AddTurn("user", ##class(DTL.Util.PromptBuilder).FeedbackPrompt(tRes, tTgtDoc))
			}

			// Clean up the throwaway attempt class (keep only the promoted winner later).
			if (tRes.className '= ..BestClassName), ##class(%Dictionary.CompiledClass).%ExistsId(tRes.className) {
				do $system.OBJ.Delete(tRes.className, "-d")
			}
		}

		// --- finalize ---
		do ..BuildResponse(.pResponse, tSuccess)
		do ..WriteArtifacts(pResponse)
	} catch ex {
		set tSC = ex.AsStatus()
		do ..BuildResponse(.pResponse, 0)
		if $isobject($get(pResponse)) set pResponse.LastError = ex.DisplayString()
	}
	quit tSC
}

/// Assemble the ForgeResponse from the loop's best-so-far state.
Method BuildResponse(Output pResponse As DTL.Msg.ForgeResponse, pSuccess As %Boolean)
{
	set pResponse = ##class(DTL.Msg.ForgeResponse).%New()
	set pResponse.JobId = ..JobId
	set pResponse.Success = pSuccess
	set pResponse.Verdict = $select(pSuccess:"SUCCESS", ..FinalVerdict'="":..FinalVerdict, 1:"FAIL_MATCH")
	set pResponse.AttemptsUsed = ..Attempt
	set pResponse.FinalScore = $select(..BestScore<0:0, 1:..BestScore)
	set pResponse.GeneratedClassName = ..BestClassName
	do ..CopyStream(..BestDTL, pResponse.FinalDTL)
	do ..CopyStream(..BestActual, pResponse.TransformedHL7)
	do pResponse.DiffSummary.Write(..BestDiffText)

	// Promote the winning DTL to a stable final name. CompileDTL re-extracts the
	// <transform> fragment from the winning source and re-wraps it under a forced
	// DTL.Generated.<leaf> name, so we only pass the desired leaf.
	if (..BestClassName '= "") && ##class(%Dictionary.CompiledClass).%ExistsId(..BestClassName) {
		set tName = ..SafeName(..Request.InputName) _ "Final"
		set tSrc = ..StreamToString(..BestDTL)
		set sc = ##class(DTL.Util.Verifier).CompileDTL(tSrc, .tName)
		if $$$ISOK(sc) set pResponse.GeneratedClassName = tName
	}

	// Finalize the linked Job record (if UI-tracked).
	do ..JobFinalize(pResponse)
}

// ---- Job-record live updates (no-ops unless JobId names a DTL.Data.Job) ----

/// Mark the linked job RUNNING and record the interop session id (for the
/// Visual Trace deep-link). Silent if no job record exists.
Method JobStart(pSessionId As %String)
{
	set tJob = ..OpenJob() quit:'$isobject(tJob)
	set tJob.Status = "RUNNING"
	set tJob.SessionId = pSessionId
	set tJob.UpdatedAt = ##class(DTL.Data.Job).Now()
	do tJob.%Save()
}

/// Append a live attempt entry to the linked job record.
Method JobAttempt(pNum As %Integer, pPhase As %String, pCompiled As %Boolean, pRan As %Boolean, pMatched As %Boolean, pScore As %Numeric, pMsg As %String)
{
	set tJob = ..OpenJob() quit:'$isobject(tJob)
	do tJob.AddAttempt(pNum, pPhase, pCompiled, pRan, pMatched, pScore, pMsg)
}

/// Write the final result into the linked job record (status, score, DTL, diff,
/// and the actual transformed output for the diff viewer).
Method JobFinalize(pResponse As DTL.Msg.ForgeResponse)
{
	set tJob = ..OpenJob() quit:'$isobject(tJob)
	set tJob.Status = $select(pResponse.Success:"SUCCESS", 1:"FAILED")
	set tJob.Verdict = pResponse.Verdict
	set tJob.Success = pResponse.Success
	set tJob.AttemptsUsed = pResponse.AttemptsUsed
	set tJob.FinalScore = pResponse.FinalScore
	set tJob.GeneratedClassName = pResponse.GeneratedClassName
	set tJob.DiffSummary = ..BestDiffText
	set tJob.LastError = pResponse.LastError
	do tJob.ActualHL7.Clear()
	do ..CopyStream(..BestActual, tJob.ActualHL7)
	do tJob.FinalDTL.Clear()
	do ..CopyStream(..BestDTL, tJob.FinalDTL)
	set tJob.UpdatedAt = ##class(DTL.Data.Job).Now()
	do tJob.%Save()
}

/// Open the DTL.Data.Job whose JobId matches this run, or "" if none.
Method OpenJob() As DTL.Data.Job
{
	quit:..JobId="" ""
	if '##class(%Dictionary.CompiledClass).%ExistsId("DTL.Data.Job") quit ""
	set tJob = ##class(DTL.Data.Job).OpenByJobId(..JobId, .sc)
	quit $select($isobject(tJob):tJob, 1:"")
}

/// Combine the user's input spec, operator Instructions, and extra sample pairs
/// into the instruction text injected into the initial LLM prompt.
Method BuildInstructions(pRequest As DTL.Msg.ForgeRequest) As %String
{
	set nl = $char(10)
	set tOut = ""
	set tSpec = ##class(DTL.Data.Job).StreamStr(pRequest.InputSpec)
	if tSpec '= "" {
		set tOut = tOut _ "Input specification (describes the input message and intended transformation):" _ nl _ tSpec _ nl _ nl
	}
	if pRequest.Instructions '= "" {
		set tOut = tOut _ pRequest.Instructions _ nl _ nl
	}
	if pRequest.SamplePairs.Count() > 0 {
		set tOut = tOut _ "Additional example input/output pairs illustrating the same transformation:" _ nl
		for i = 1:1:pRequest.SamplePairs.Count() {
			set tP = pRequest.SamplePairs.GetAt(i)
			set tOut = tOut _ nl _ "--- Example " _ (i + 1) _ " INPUT ---" _ nl _ ##class(DTL.Util.PromptBuilder).PrettyHL7(tP.InputHL7) _ nl
			set tOut = tOut _ "--- Example " _ (i + 1) _ " OUTPUT ---" _ nl _ ##class(DTL.Util.PromptBuilder).PrettyHL7(tP.OutputHL7) _ nl
		}
	}
	quit tOut
}

/// Write artifacts (winning .cls and a result summary) to ArtifactDir if set.
Method WriteArtifacts(pResponse As DTL.Msg.ForgeResponse)
{
	quit:..ArtifactDir=""
	try {
		set tDir = ..ArtifactDir
		if $extract(tDir, *) '= "/" set tDir = tDir _ "/"
		set tBase = ..SafeName(..Request.InputName)
		// winning DTL class source
		set tFile = ##class(%Stream.FileCharacter).%New()
		set tFile.Filename = tDir _ tBase _ ".dtl.cls"
		do ..CopyStream(..BestDTL, tFile)
		do tFile.%Save()
		// result summary
		set tSummary = {
			"jobId": (..JobId),
			"input": (..Request.InputName),
			"success": (pResponse.Success),
			"verdict": (pResponse.Verdict),
			"attemptsUsed": (pResponse.AttemptsUsed),
			"finalScore": (pResponse.FinalScore),
			"generatedClass": (pResponse.GeneratedClassName)
		}
		set tRF = ##class(%Stream.FileCharacter).%New()
		set tRF.Filename = tDir _ tBase _ ".result.json"
		do tRF.Write(tSummary.%ToJSON())
		do tRF.%Save()
	} catch ex {
		$$$LOGWARNING("Artifact write failed: "_ex.DisplayString())
	}
}

// -------------------- helpers --------------------

Method AddTurn(pRole As %String, pContent As %String)
{
	set t = ##class(DTL.Msg.ChatTurn).%New()
	set t.Role = pRole
	set t.Content = pContent
	do ..Transcript.Insert(t)
}

ClassMethod StreamToString(pStream As %Stream.Object) As %String
{
	quit:'$isobject(pStream) ""
	do pStream.Rewind()
	set s = ""
	while 'pStream.AtEnd { set s = s _ pStream.Read(16000) }
	quit s
}

ClassMethod SetStream(pStream As %Stream.Object, pValue As %String)
{
	do pStream.Clear()
	do pStream.Write(pValue)
}

ClassMethod CopyStream(pFrom As %Stream.Object, pTo As %Stream.Object)
{
	quit:'$isobject(pFrom)
	do pFrom.Rewind()
	while 'pFrom.AtEnd { do pTo.Write(pFrom.Read(16000)) }
}

ClassMethod SafeName(pName As %String) As %String
{
	set out = ""
	for i = 1:1:$length(pName) {
		set c = $extract(pName, i)
		if (c?1(1A,1N)) set out = out _ c
	}
	if (out '= ""), '($extract(out)?1A) set out = "X" _ out
	quit $select(out'="":out, 1:"Job")
}

}
