/// Bridges the REST layer and the interoperability production.
///
/// StartJob() turns a UI payload (input spec + N sample pairs + options) into a
/// persistent DTL.Data.Job record and dispatches a DTL.Msg.ForgeRequest
/// ASYNCHRONOUSLY into the running production's orchestrator. The orchestrator
/// updates the same Job record attempt-by-attempt, so the REST GET endpoint can
/// poll it for live progress. The POST therefore returns immediately with a jobId.
Class DTL.Service.JobManager Extends %RegisteredObject
{

/// Config item to dispatch into (the orchestrator BP).
Parameter TARGET = "DTL.Proc.Orchestrator";

/// Create a Job from a parsed payload and kick off async generation.
/// pPayload is a %DynamicObject with:
///   inputSpec      (string, optional)
///   inputName      (string, optional display name)
///   maxAttempts    (int, optional)
///   successPolicy  (string, optional)
///   matchThreshold (number, optional)
///   pairs          (array of {input, output}), at least one required
/// Returns the new jobId via output; pSC carries any error.
ClassMethod StartJob(pPayload As %DynamicObject, Output pJobId As %String, Output pSC As %Status) As %Status
{
	set pSC = $$$OK, pJobId = ""
	try {
		// --- SPEC-DRIVEN: the transformation is defined by the spec. All messages
		// are INPUTS; there are NO expected outputs. The first input is primary
		// (the DTL is run on it; gate = compile+run). Legacy pairs[].input still
		// works as an input source. ---
		set tInputs = ..CollectMessages(pPayload, "inputs", "input")
		set tIn = $listget(tInputs, 1)
		if (tIn = "") {
			set pSC = $$$ERROR($$$GeneralError, "At least one example INPUT message is required.")
			quit
		}
		set tSpec = pPayload.inputSpec
		if $zstrip(tSpec, "<>W") = "" {
			set pSC = $$$ERROR($$$GeneralError, "An input specification (text or document) is required.")
			quit
		}
		set tOut = tIn   // no expected output; the primary input is also the run target

		set pJobId = ..NewJobId()
		set tName = pPayload.inputName
		if tName = "" set tName = "Job_" _ pJobId

		// Store ALL input messages for later transform-all + review.
		kill ^DTL.JobInputs(pJobId)
		set tN = $listlength(tInputs)
		for i = 1:1:tN { set ^DTL.JobInputs(pJobId, i) = $listget(tInputs, i) }

		// Gated (per-attempt approval) is the default for the UI; auto-approve is
		// used by the file service / tests (run straight through, no pauses).
		set tAuto = $select(pPayload.autoApprove="":0, 1:''pPayload.autoApprove)

		// --- create the persistent Job record ---
		set tJob = ##class(DTL.Data.Job).%New()
		set tJob.JobId = pJobId
		set tJob.Status = "QUEUED"
		set tJob.InputName = tName
		do tJob.InputSpec.Write(tSpec)
		set tJob.MaxAttempts = $select(pPayload.maxAttempts'="":+pPayload.maxAttempts, 1:5)
		// Spec-driven jobs gate on compile+run (no expected output to diff).
		set tJob.SuccessPolicy = "CompileRun"
		set tJob.Provider = pPayload.provider
		set tJob.Model = pPayload.model   // store the model (NOT the key) for display
		set tJob.ParentJobId = pPayload.parentJobId
		set tJob.SourceDocType = ##class(DTL.Util.HL7).DeriveDocType(tIn)
		// Default target = same structure as the input, upgraded version if the
		// spec mentions one is left to the LLM; pin target to source by default.
		set tJob.TargetDocType = ##class(DTL.Util.HL7).DeriveDocType(tIn)
		do tJob.SourceHL7.Write(tIn)
		do tJob.ExpectedHL7.Write(tOut)
		set tJob.CreatedAt = ##class(DTL.Data.Job).Now()
		set tJob.UpdatedAt = tJob.CreatedAt
		set pSC = tJob.%Save()
		quit:$$$ISERR(pSC)

		// Stash the API key OUT of the Job record (transient global, per job).
		if pPayload.apiKey '= "" set ^DTL.JobKey(pJobId) = pPayload.apiKey

		if tAuto {
			// ----- legacy auto-run path: async ForgeRequest into the BP -----
			set tReq = ##class(DTL.Msg.ForgeRequest).%New()
			set tReq.JobId = pJobId
			set tReq.InputName = tName
			do tReq.InputSpec.Write(tJob.StreamStr(tJob.InputSpec))    // includes folded extra examples
			do tReq.SourceHL7.Write(tIn)
			do tReq.TargetHL7.Write(tOut)
			set tReq.SourceDocType = tJob.SourceDocType
			set tReq.TargetDocType = tJob.TargetDocType
			set tReq.MaxAttempts = tJob.MaxAttempts
			set tReq.SuccessPolicy = tJob.SuccessPolicy
			set tReq.MatchThreshold = $select(pPayload.matchThreshold'="":+pPayload.matchThreshold, 1:0.85)
			set tReq.Provider = pPayload.provider
			set tReq.Model = pPayload.model
			set tReq.ApiKey = pPayload.apiKey
			set pSC = ..DispatchAsync(tReq)
			if $$$ISERR(pSC) {
				set tJob.Status = "FAILED"
				set tJob.LastError = "Dispatch failed: " _ $system.Status.GetErrorText(pSC)
				do tJob.%Save()
			}
		} else {
			// ----- gated path: run the PLAN step now; UI approves to continue -----
			set pSC = ##class(DTL.Service.StepEngine).Plan(tJob)
		}
	} catch ex {
		set pSC = ex.AsStatus()
	}
	quit pSC
}

/// Collect example messages of one kind into a %List of trimmed HL7 strings.
/// Reads the new independent array pPayload.<pArrayKey> (array of strings), and
/// falls back to the legacy pPayload.pairs[].<pPairField> form. Messages are NOT
/// assumed to be paired across the two kinds.
ClassMethod CollectMessages(pPayload As %DynamicObject, pArrayKey As %String, pPairField As %String) As %List
{
	set tOut = ""
	set tArr = pPayload.%Get(pArrayKey)
	if $isobject(tArr) {
		set it = tArr.%GetIterator()
		while it.%GetNext(.k, .v) {
			set tv = $zstrip($select($isobject(v):"", 1:v), "<>W")
			if tv '= "" set tOut = tOut _ $listbuild(tv)
		}
	}
	// legacy pairs[] fallback
	if (tOut = ""), $isobject(pPayload.pairs) {
		set it = pPayload.pairs.%GetIterator()
		while it.%GetNext(.k, .p) {
			continue:'$isobject(p)
			set tv = $zstrip(p.%Get(pPairField), "<>W")
			if tv '= "" set tOut = tOut _ $listbuild(tv)
		}
	}
	quit tOut
}

/// Build a labelled context block from the NON-primary example messages, making
/// explicit that inputs and outputs are NOT matched pairs.
ClassMethod ExtraExamplesText(pInputs As %List, pOutputs As %List) As %String
{
	set nl = $char(10)
	set tHasExtra = ($listlength(pInputs) > 1) || ($listlength(pOutputs) > 1)
	quit:'tHasExtra ""
	set t = "ADDITIONAL EXAMPLE MESSAGES (illustrative; the example inputs and outputs are NOT necessarily matched pairs — infer the general transformation rules, do not assume input[i] maps to output[i]):" _ nl
	for i = 2:1:$listlength(pInputs) {
		set t = t _ nl _ "--- example INPUT ---" _ nl _ ##class(DTL.Util.PromptBuilder).PrettyHL7($listget(pInputs, i))
	}
	for i = 2:1:$listlength(pOutputs) {
		set t = t _ nl _ "--- example OUTPUT ---" _ nl _ ##class(DTL.Util.PromptBuilder).PrettyHL7($listget(pOutputs, i))
	}
	quit t
}

/// Advance a gated job one step in response to a UI action.
///   action="approve" (approve the plan) or "accept" (accept the pending attempt)
///   action="reject"  with pFeedback -> regenerate addressing the feedback
ClassMethod Continue(pJobId As %String, pAction As %String, pFeedback As %String = "", Output pSC As %Status) As %Status
{
	set pSC = $$$OK
	set tJob = ##class(DTL.Data.Job).OpenByJobId(pJobId, .sc)
	if '$isobject(tJob) { set pSC = $$$ERROR($$$GeneralError, "No job '" _ pJobId _ "'") quit pSC }
	if pAction = "approve" {
		set pSC = ##class(DTL.Service.StepEngine).GenerateOne(tJob)
	} elseif pAction = "accept" {
		set pSC = ##class(DTL.Service.StepEngine).Accept(tJob)
	} elseif pAction = "reject" {
		set pSC = ##class(DTL.Service.StepEngine).Reject(tJob, pFeedback)
	} else {
		set pSC = $$$ERROR($$$GeneralError, "Unknown action '" _ pAction _ "'")
	}
	quit pSC
}

/// Create a refinement job from a finished one: reuse the same pair + spec but
/// seed it with the parent's final DTL and the user's feedback, then run a fresh
/// (gated) plan/attempt cycle. Returns the new jobId.
ClassMethod Refine(pParentId As %String, pFeedback As %String, Output pJobId As %String, Output pSC As %Status) As %Status
{
	set pSC = $$$OK, pJobId = ""
	set tParent = ##class(DTL.Data.Job).OpenByJobId(pParentId, .sc)
	if '$isobject(tParent) { set pSC = $$$ERROR($$$GeneralError, "No parent job '" _ pParentId _ "'") quit pSC }
	set tSpec = tParent.StreamStr(tParent.InputSpec) _ $char(10,10) _ "REFINEMENT FEEDBACK on the previous DTL:" _ $char(10) _ pFeedback
	set tSpec = tSpec _ $char(10,10) _ "Previous DTL produced:" _ $char(10) _ tParent.StreamStr(tParent.FinalDTL)
	set tPayload = {}
	set tPayload.inputName = tParent.InputName _ " (refined)"
	set tPayload.inputSpec = tSpec
	set tPayload.provider = tParent.Provider
	set tPayload.model = tParent.Model
	set tPayload.apiKey = $get(^DTL.JobKey(pParentId))
	set tPayload.successPolicy = tParent.SuccessPolicy
	set tPayload.maxAttempts = tParent.MaxAttempts
	set tPayload.parentJobId = pParentId
	set tIns = [] do tIns.%Push(tParent.StreamStr(tParent.SourceHL7))
	set tOuts = [] do tOuts.%Push(tParent.StreamStr(tParent.ExpectedHL7))
	set tPayload.inputs = tIns
	set tPayload.outputs = tOuts
	set pSC = ..StartJob(tPayload, .pJobId, .tStartSC)
	if $$$ISERR(tStartSC) set pSC = tStartSC
	quit pSC
}

/// Outputs of transforming every stored input with the job's final DTL.
/// Returns a %DynamicArray of {index, input, output, error}.
ClassMethod Outputs(pJobId As %String) As %DynamicArray
{
	set arr = []
	set n = $order(^DTL.JobOutputs(pJobId, ""), -1)
	if n = "" quit arr
	for i = 1:1:n {
		set row = $get(^DTL.JobOutputs(pJobId, i))
		continue:row=""
		set o = {}
		set o.index = i, o.input = $listget(row, 1), o.output = $listget(row, 2), o.error = $listget(row, 3)
		do arr.%Push(o)
	}
	quit arr
}

/// All DTL classes generated this session: the promoted DTL.Generated.*Final
/// classes (+ any in the package), with their source. %DynamicArray of
/// {className, jobId, inputName, source}.
ClassMethod Classes() As %DynamicArray
{
	set arr = []
	// list compiled classes in the DTL.Generated package
	set tStmt = ##class(%SQL.Statement).%New()
	set sc = tStmt.%Prepare("SELECT ID FROM %Dictionary.CompiledClass WHERE ID %STARTSWITH 'DTL.Generated.' AND ID [ 'Final'")
	if $$$ISOK(sc) {
		set rs = tStmt.%Execute()
		while rs.%Next() {
			set cls = rs.%Get("ID")
			set o = {}
			set o.className = cls
			set o.source = ..ClassSource(cls)
			do arr.%Push(o)
		}
	}
	quit arr
}

/// Export a compiled class's source (UDL) to a string.
ClassMethod ClassSource(pClass As %String) As %String
{
	set tStream = ##class(%Stream.GlobalCharacter).%New()
	set sc = ##class(%Compiler.UDL.TextServices).GetTextAsStream($namespace, pClass, .tStream)
	quit:$$$ISERR(sc) ""
	set t = "" do tStream.Rewind()
	while 'tStream.AtEnd { set t = t _ tStream.Read(16000) }
	quit t
}

/// Live transform: run a job's final DTL on an arbitrary input, return the output.
ClassMethod Transform(pJobId As %String, pInput As %String, Output pOutput As %String, Output pErr As %String) As %Status
{
	set pOutput = "", pErr = ""
	set tJob = ##class(DTL.Data.Job).OpenByJobId(pJobId, .sc)
	if '$isobject(tJob) { set pErr = "no job" quit $$$ERROR($$$GeneralError, pErr) }
	if tJob.GeneratedClassName = "" { set pErr = "no DTL built yet" quit $$$ERROR($$$GeneralError, pErr) }
	quit ##class(DTL.Util.Verifier).RunTransform(tJob.GeneratedClassName, pInput, tJob.SourceDocType, .pOutput, .pErr)
}

/// Apply a correction (corrected output + feedback for a given input) and rebuild.
ClassMethod CorrectJob(pJobId As %String, pInput As %String, pProduced As %String, pCorrected As %String, pFeedback As %String, Output pSC As %Status) As %Status
{
	set pSC = $$$OK
	set tJob = ##class(DTL.Data.Job).OpenByJobId(pJobId, .sc)
	if '$isobject(tJob) { set pSC = $$$ERROR($$$GeneralError, "no job '" _ pJobId _ "'") quit pSC }
	set pSC = ##class(DTL.Service.StepEngine).Correct(tJob, pInput, pProduced, pCorrected, pFeedback)
	quit pSC
}

/// Send the ForgeRequest asynchronously into the orchestrator via the built-in
/// testing service, so the HTTP request can return immediately.
ClassMethod DispatchAsync(pReq As DTL.Msg.ForgeRequest) As %Status
{
	if '##class(Ens.Director).IsProductionRunning() {
		quit $$$ERROR($$$GeneralError, "The DTL production is not running. Start it (DTL.Setup.Installer.Run) first.")
	}
	set tSC = ##class(Ens.Director).CreateBusinessService("EnsLib.Testing.Service", .tSvc)
	quit:$$$ISERR(tSC) tSC
	quit tSvc.SendRequestAsync(..#TARGET, pReq)
}

/// Generate a short, unique, URL-safe job id (lowercase hex, no underscores).
ClassMethod NewJobId() As %String
{
	set tId = ..RandHex()
	// ensure uniqueness against existing records
	while ##class(DTL.Data.Job).JobIdIdxExists(tId) {
		set tId = ..RandHex()
	}
	quit tId
}

/// 12-char lowercase hex id from 6 random bytes ($zhex of a byte string returns
/// 0, so we hex-encode each byte explicitly).
ClassMethod RandHex() As %String
{
	set tBytes = $system.Encryption.GenCryptRand(6)
	set tHex = ""
	for i = 1:1:$length(tBytes) {
		set tHex = tHex _ $zconvert($extract($zhex(256 + $ascii($extract(tBytes, i))), 2, 3), "L")
	}
	quit tHex
}

}
