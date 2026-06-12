/// Drives the GATED (human-in-the-loop) DTL workflow as discrete, synchronous
/// steps, persisting all state on the DTL.Data.Job so each REST /continue call
/// advances exactly one step and the conversation survives across user think-time.
///
/// State machine (gated jobs) — accuracy-first, errors caught as EARLY as possible:
///   QUEUED         -> (StructureSpec) -> AWAITING_SPEC
///   AWAITING_SPEC  -(approve spec)->     PLANNING -> AWAITING_PLAN
///   AWAITING_PLAN  -(approve)->          GENERATING -> [JUDGING] -> AWAITING_ATTEMPT
///   AWAITING_ATTEMPT-(accept)->          SUCCESS
///   AWAITING_ATTEMPT-(reject,fb)->       GENERATING -> AWAITING_ATTEMPT (next attempt)
///
/// The AWAITING_SPEC gate is new and deliberate: the raw extracted spec is first
/// restructured into an explicit, numbered RULE LIST with provenance back to the
/// original, and the human verifies it BEFORE any planning/DTL — so an extraction
/// or interpretation error is caught at the cheapest possible point. The approved
/// structured spec then becomes the AUTHORITY for every downstream step, and the
/// success gate verifies the DTL against THE SPEC (compile + run-all-inputs +
/// rule-coverage + LLM-as-judge conformance), not merely "did it run".
///
/// Each LLM call goes through a transient EnsLib.Testing.Service so it is fully
/// traced (the Job records the latest interop SessionId for the Visual Trace).
/// The auto-run (ungated) path still lives in DTL.Proc.Orchestrator.
Class DTL.Service.StepEngine Extends %RegisteredObject
{

Parameter LLMTARGET = "DTL.Op.LLMConnector";

/// STEP 0 — restructure the raw spec into an explicit rule list (with provenance)
/// for human review. Moves QUEUED -> STRUCTURING -> AWAITING_SPEC. The raw-spec
/// turns are kept in the transcript for visibility but flagged so they are NOT
/// re-sent on every later build call (the compact structured spec is used instead).
ClassMethod StructureSpec(pJob As DTL.Data.Job) As %Status
{
	set tSC = $$$OK
	try {
		set pJob.Status = "STRUCTURING"
		do pJob.%Save()
		set tRaw = pJob.StreamStr(pJob.InputSpec)
		// A lightweight system role for the structuring call (NOT the heavy build
		// system prompt — structuring doesn't need the DTL element schema).
		do pJob.AddTurn("system", "You convert clinical interface specifications into explicit, reviewable, machine-checkable rule lists. You never invent requirements.")
		do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).SpecStructurePrompt(tRaw, pJob.SourceDocType, ..InputsBlock(pJob)))
		set tReply = ..CallLLM(pJob, .tSession, .tErr, 1, .tInTok, .tOutTok, .tCost)
		set pJob.SessionId = tSession
		if tReply = "" {
			set pJob.Status = "FAILED", pJob.LastError = "Spec-structuring LLM call failed: " _ tErr
			do pJob.%Save()
			quit
		}
		do ..AddAssistantTurn(pJob, tReply, tInTok, tOutTok, tCost)
		// Parse the JSON the model returned; fall back to treating the raw reply as
		// the structured spec if it didn't return clean JSON (never hard-fail here).
		do ..ApplyStructuredSpec(pJob, tReply)
		set pJob.Status = "AWAITING_SPEC"
		set pJob.UpdatedAt = ##class(DTL.Data.Job).Now()
		do pJob.%Save()
	} catch ex {
		set tSC = ex.AsStatus()
		set pJob.Status = "FAILED", pJob.LastError = ex.DisplayString()
		do pJob.%Save()
	}
	quit tSC
}

/// Re-run the structuring step after the reviewer rejected the structured spec.
/// The rejection feedback is already appended to the transcript; we resend it (the
/// build conversation hasn't started, so the whole transcript including the raw
/// spec is sent) and re-parse the result. Stays in AWAITING_SPEC.
ClassMethod StructureSpecRetry(pJob As DTL.Data.Job) As %Status
{
	set tSC = $$$OK
	try {
		set pJob.Status = "STRUCTURING"
		do pJob.%Save()
		set tReply = ..CallLLM(pJob, .tSession, .tErr, 1, .tInTok, .tOutTok, .tCost)
		set pJob.SessionId = tSession
		if tReply = "" {
			set pJob.Status = "AWAITING_SPEC", pJob.LastError = "Re-structuring failed: " _ tErr
			do pJob.%Save()
			quit
		}
		do ..AddAssistantTurn(pJob, tReply, tInTok, tOutTok, tCost)
		do ..ApplyStructuredSpec(pJob, tReply)
		set pJob.Status = "AWAITING_SPEC", pJob.LastError = ""
		set pJob.UpdatedAt = ##class(DTL.Data.Job).Now()
		do pJob.%Save()
	} catch ex {
		set tSC = ex.AsStatus()
		set pJob.Status = "AWAITING_SPEC", pJob.LastError = ex.DisplayString()
		do pJob.%Save()
	}
	quit tSC
}

/// Parse the structuring reply (strict JSON) into the human-readable StructuredSpec
/// markdown + the SpecProvenance JSON the review UI renders side-by-side. Tolerant:
/// if the reply isn't valid JSON, store it verbatim as the structured spec so the
/// human can still edit it.
ClassMethod ApplyStructuredSpec(pJob As DTL.Data.Job, pReply As %String)
{
	set tJson = ..ParseJSONBlock(pReply)
	if '$isobject(tJson) {
		// Not JSON — keep the model's text as the structured spec, empty provenance.
		do pJob.StructuredSpec.Clear()  do pJob.StructuredSpec.Write(pReply)
		do pJob.SpecProvenance.Clear()  do pJob.SpecProvenance.Write("[]")
		quit
	}
	set nl = $char(10)
	set tMd = "", tProv = []
	if tJson.title '= "" set tMd = "# " _ tJson.title _ nl _ nl
	set tMd = tMd _ "## Transformation rules" _ nl
	if $isobject(tJson.rules) {
		set it = tJson.rules.%GetIterator()
		while it.%GetNext(.k, .r) {
			continue:'$isobject(r)
			set tIdx = $select(r.index'="":+r.index, 1:(tProv.%Size() + 1))
			set tRuleTxt = r.rule
			set tInferred = ''r.inferred
			set tMd = tMd _ tIdx _ ". " _ tRuleTxt _ $select(tInferred:"  _(inferred)_", 1:"") _ nl
			set tP = {}
			set tP.ruleIndex = tIdx
			set tP.rule = tRuleTxt
			set tP.sourceQuote = r.sourceQuote
			set tP.inferred = tInferred
			do tProv.%Push(tP)
		}
	}
	if $isobject(tJson.ambiguities), tJson.ambiguities.%Size() > 0 {
		set tMd = tMd _ nl _ "## Ambiguities / decisions needed" _ nl
		set it2 = tJson.ambiguities.%GetIterator()
		while it2.%GetNext(.k2, .a) { set tMd = tMd _ "- " _ a _ nl }
	}
	do pJob.StructuredSpec.Clear()  do pJob.StructuredSpec.Write(tMd)
	do pJob.SpecProvenance.Clear()  do pJob.SpecProvenance.Write(tProv.%ToJSON())
}

/// Run the PLAN step AFTER the human approves the structured spec. Seeds the
/// cacheable BUILD SYSTEM PROMPT (DTL rules + HL7 schema + approved spec) and marks
/// the build-conversation start, then asks for a short implementation plan. Moves
/// the job to AWAITING_PLAN.
/// Background entry point for planning (JOB'd by JobManager.StartJob for an approved
/// concise spec). Opens the job by id and runs the synchronous Plan so the slow LLM
/// calls (incl. the plan-coverage re-plan loop) happen OUT of the HTTP request.
///
/// CRITICAL: this runs in a spawned process, so the Job record is the ONLY channel
/// back to the polling UI. If anything throws here (or in Plan) before a status is
/// written, the job would be stuck at QUEUED/PLANNING forever with no error and the
/// interop message stuck at "Delivered". So we wrap everything and, on ANY failure,
/// write FAILED + the error onto the job so the UI surfaces it instead of hanging.
ClassMethod PlanJob(pJobId As %String)
{
	try {
		set tJob = ##class(DTL.Data.Job).OpenByJobId(pJobId, .sc)
		if '$isobject(tJob) quit
		do ..Plan(tJob)
	} catch ex {
		do ..FailJob(pJobId, "Planning failed: " _ ex.DisplayString())
	}
}

/// Background entry point for in-job spec structuring (JOB'd for a never-reviewed
/// typed spec). Same rationale + silent-death guard as PlanJob.
ClassMethod StructureSpecJob(pJobId As %String)
{
	try {
		set tJob = ##class(DTL.Data.Job).OpenByJobId(pJobId, .sc)
		if '$isobject(tJob) quit
		do ..StructureSpec(tJob)
	} catch ex {
		do ..FailJob(pJobId, "Spec structuring failed: " _ ex.DisplayString())
	}
}

/// Mark a job FAILED with an error message — best-effort, used by the background
/// entry points so a spawned-process crash never leaves a job silently stuck.
ClassMethod FailJob(pJobId As %String, pMsg As %String)
{
	try {
		set tJob = ##class(DTL.Data.Job).OpenByJobId(pJobId, .sc)
		quit:'$isobject(tJob)
		set tJob.Status = "FAILED", tJob.LastError = $extract(pMsg, 1, 1800)
		set tJob.UpdatedAt = ##class(DTL.Data.Job).Now()
		do tJob.%Save()
	} catch {}
}

ClassMethod Plan(pJob As DTL.Data.Job) As %Status
{
	set tSC = $$$OK
	try {
		set pJob.Status = "PLANNING"
		do pJob.%Save()
		set tSpec = pJob.StreamStr(pJob.StructuredSpec)
		if $zstrip(tSpec, "<>W") = "" set tSpec = pJob.StreamStr(pJob.InputSpec)   // safety net
		// The single cacheable static prefix for the whole build conversation.
		do pJob.AddTurn("system", ##class(DTL.Util.PromptBuilder).BuildSystemPrompt(tSpec, pJob.SourceDocType, pJob.TargetDocType))
		do pJob.MarkBuildStart()     // everything from here is re-sent each build call; prior raw-spec turns are not
		do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).PlanFromSpecPrompt())
		set tReply = ..CallLLM(pJob, .tSession, .tErr, 1, .tInTok, .tOutTok, .tCost)
		if tReply = "" {
			set pJob.Status = "FAILED", pJob.LastError = "Planning LLM call failed: " _ tErr
			do pJob.%Save()
			quit
		}
		set pJob.SessionId = tSession
		do ..AddAssistantTurn(pJob, tReply, tInTok, tOutTok, tCost)

		// COVERAGE GATE: every specification rule THAT APPLIES TO THIS MESSAGE TYPE must
		// be accounted for in the plan, so a conditional/"runtime" rule (e.g. a "required
		// when…" constraint) can't be silently dropped and then missing from the DTL. We
		// scope by the segments that exist in this message's structure, so rules for OTHER
		// message types (ACK/SIU/REF/… segments not in this DocType) are NOT demanded —
		// that scoping is also why the plan stays a realistic size instead of enumerating
		// every rule in a multi-message spec. Bounded retries so a stubborn model can't loop.
		set tSegSet = ##class(DTL.Util.HL7Schema).SegmentSet(pJob.SourceDocType)
		for tCov = 1:1:2 {
			set tMissing = ..UncoveredRules(tSpec, tReply, tSegSet)
			quit:tMissing=""
			do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).PlanCoverageFixPrompt(tMissing))
			set tReply2 = ..CallLLM(pJob, .tSession, .tErr, 1, .tInTok, .tOutTok, .tCost)
			quit:tReply2=""    // transport hiccup: keep the best plan we have, don't fail the step
			set pJob.SessionId = tSession
			do ..AddAssistantTurn(pJob, tReply2, tInTok, tOutTok, tCost)
			set tReply = tReply2
		}

		// CONDITIONAL-REQUIREMENT GATE: a rule the spec states as 'required when…' must be
		// ENFORCED by the DTL (an <if>), not assumed already-present. Catch any such rule
		// the plan downgraded to 'passed through unchanged' and make the model re-classify
		// it. (Prompt guidance alone has flip-flopped between dropping it and truncating it;
		// this deterministic check keeps a runtime rule from silently becoming a no-op.)
		for tCond = 1:1:2 {
			set tMisclass = ..MisclassifiedConditionals(tSpec, tReply, tSegSet)
			quit:tMisclass=""
			do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).PlanConditionalFixPrompt(tMisclass))
			set tReply3 = ..CallLLM(pJob, .tSession, .tErr, 1, .tInTok, .tOutTok, .tCost)
			quit:tReply3=""
			set pJob.SessionId = tSession
			do ..AddAssistantTurn(pJob, tReply3, tInTok, tOutTok, tCost)
			set tReply = tReply3
		}

		set pJob.Plan = $extract(tReply, 1, 32000)
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

/// Approve the plan (or accept after a rejection) and run generation attempts with
/// an ACCURACY GATE. Each attempt: ask the LLM, compile, run on ALL inputs, check
/// rule coverage (did the DTL actually change anything), and run an LLM-as-judge
/// conformance pass against the approved spec. Auto-repair on COMPILE/RUNTIME/GATE
/// failure until it passes, the budget (MaxAttempts) is hit, the cost cap is hit,
/// or it plateaus (identical candidate / no progress). Then pause at
/// AWAITING_ATTEMPT for the human's final accept.
ClassMethod GenerateOne(pJob As DTL.Data.Job) As %Status
{
	set tSC = $$$OK
	try {
		set tPrimary = pJob.StreamStr(pJob.SourceHL7)
		set tSpec = pJob.StreamStr(pJob.StructuredSpec)
		if $zstrip(tSpec, "<>W") = "" set tSpec = pJob.StreamStr(pJob.InputSpec)
		set tMax = $select(pJob.MaxAttempts>0:pJob.MaxAttempts, 1:5)
		set tFirstTurn = (pJob.AttemptsUsed = 0)
		set tLastHash = "", tLastScore = -1, tPlateau = 0
		for {
			set tAttempt = pJob.AttemptsUsed + 1
			set pJob.Status = "GENERATING"
			do pJob.%Save()
			set tClassName = "DTL.Generated." _ ..SafeName(pJob.InputName) _ "Job" _ ..SafeName(pJob.JobId) _ "A" _ tAttempt

			if tFirstTurn {
				// The input message is NOT sent — generation is from the spec only.
				do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).InitialFromSpecPrompt(tClassName, pJob.SourceDocType, pJob.TargetDocType))
				set tFirstTurn = 0
			}

			set tReply = ..CallLLM(pJob, .tSession, .tErr, 0, .tInTok, .tOutTok, .tCost)
			set pJob.SessionId = tSession
			if tReply = "" {
				do pJob.AddAttempt(tAttempt, "LLM_ERROR", 0, 0, 0, 0, "LLM call failed: " _ tErr)
				set pJob.Status = "AWAITING_ATTEMPT", pJob.Verdict = "LLM_ERROR"
				set pJob.LastError = tErr
				do pJob.%Save()
				quit
			}

			set tClassSrc = ##class(DTL.Util.Extractor).Extract(tReply, .tCN, .tValid)
			do ..AddAssistantTurn(pJob, tClassSrc, tInTok, tOutTok, tCost)

			// --- compile + run on the PRIMARY input first (cheap gate before judge) ---
			set tName = tClassName
			set tRes = ##class(DTL.Util.Verifier).VerifyAll(tClassSrc, tPrimary, tPrimary, pJob.SourceDocType, "CompileRun", .tName)
			set tActual = ""
			try { set tActual = tRes.actual } catch {}

			// Stage the candidate so the UI can show its DTL + output even mid-repair.
			do pJob.FinalDTL.Clear()        do pJob.FinalDTL.Write(tClassSrc)
			do pJob.ActualHL7.Clear()       do pJob.ActualHL7.Write(tActual)
			set pJob.GeneratedClassName = tRes.className

			if 'tRes.compiled {
				set tPhase = "COMPILE_FAIL"
				set tNote = "Did not compile. " _ ..FirstLines(tRes.compileErrors, 4)
				set tGateReport = {"stage":"compile","ok":0}
			} elseif 'tRes.ran {
				set tPhase = "RUNTIME_FAIL"
				set tNote = "Compiled, but failed at runtime: " _ ..FirstLines($get(tRes.runErrors), 3)
				set tGateReport = {"stage":"runtime","ok":0}
			} else {
				// --- ACCURACY GATE: run ALL inputs + coverage + LLM judge vs the spec ---
				set tPhase = ..AccuracyGate(pJob, tClassName, tSpec, tActual, .tGateReport, .tGateFindings, .tScore)
				set tNote = $case(tPhase,
					"SUCCESS":"Compiled, ran on all inputs, and conforms to the spec (judge score " _ $fnumber(tScore, "", 2) _ ").",
					:"Compiled & ran but does not yet satisfy the spec (judge score " _ $fnumber(tScore, "", 2) _ "). " _ ..FirstLines(tGateFindings, 3))
				set pJob.FinalScore = +tScore
			}

			do pJob.AddAttempt(tAttempt, tPhase, tRes.compiled, tRes.ran, (tPhase="SUCCESS"), +$get(tScore), tNote)
			do pJob.GateReport.Clear()  do pJob.GateReport.Write(tGateReport.%ToJSON())
			set pJob.Verdict = $select(tPhase="SUCCESS":"SUCCESS", tPhase="COMPILE_FAIL":"FAIL_COMPILE", tPhase="RUNTIME_FAIL":"FAIL_RUNTIME", 1:"FAIL_SPEC")
			set pJob.LastError = $select(tPhase="SUCCESS":"", tPhase="COMPILE_FAIL":"Compile error: " _ ..FirstLines(tRes.compileErrors, 6), tPhase="RUNTIME_FAIL":"Runtime error: " _ ..FirstLines($get(tRes.runErrors), 4), 1:"Spec conformance: " _ ..FirstLines($get(tGateFindings), 4))
			do pJob.%Save()

			// Success, out of budget, or cost cap -> pause for the user.
			if tPhase = "SUCCESS" quit
			if tAttempt >= tMax quit
			if ..OverCostCap(pJob) {
				set pJob.LastError = "Stopped: job cost cap ($" _ pJob.CostCap _ ") reached after attempt " _ tAttempt _ ". Review the latest candidate or raise the cap."
				do pJob.%Save()
				quit
			}

			// Plateau / cycle guard: stop auto-repair if the model returns an identical
			// candidate or stops improving, so we don't burn the budget unproductively.
			set tHash = $zcrc(tClassSrc, 7)
			if (tHash = tLastHash) {
				set pJob.LastError = "Stopped: the model returned an identical candidate twice (no progress). Review or give specific feedback."
				do pJob.%Save()
				quit
			}
			if (tLastScore >= 0) && (+$get(tScore) <= (tLastScore + 0.001)) {
				set tPlateau = tPlateau + 1
				if tPlateau >= 2 {
					set pJob.LastError = "Stopped: spec-conformance score is not improving across attempts. Review or give specific feedback."
					do pJob.%Save()
					quit
				}
			} else { set tPlateau = 0 }
			set tLastHash = tHash, tLastScore = +$get(tScore)

			// Auto-repair: feed back the right kind of error.
			if tPhase = "COMPILE_FAIL" {
				do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).CompileFixPrompt(tRes.compileErrors, pJob.SourceDocType, pJob.TargetDocType))
			} elseif tPhase = "RUNTIME_FAIL" {
				do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).RuntimeFixPrompt($get(tRes.runErrors), pJob.SourceDocType, pJob.TargetDocType))
			} else {
				do pJob.AddTurn("user", ##class(DTL.Util.PromptBuilder).GateFixPrompt($get(tGateFindings)))
			}
		}

		// Settle into AWAITING_ATTEMPT unless an LLM transport error already moved the
		// job elsewhere. The gate transiently sets JUDGING, so accept either.
		if (pJob.Status = "GENERATING") || (pJob.Status = "JUDGING") {
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

/// THE ACCURACY GATE. Given a compiled+ran candidate, verify it against the SPEC,
/// not just "did it run". Three signals:
///  1. RunAll  — runs the DTL over EVERY stored input (the example input may not
///     exercise every rule; a DTL must not break on the others).
///  2. Coverage — proves the DTL actually CHANGED fields (a spec-driven transform
///     that changes nothing means every assign was silently swallowed on a bad path).
///  3. LLM judge — a fresh-perspective grader decides if the produced output
///     satisfies each spec rule, returning concrete violations.
/// Returns "SUCCESS" or "MISMATCH" (spec not yet met); fills pReport (JSON object),
/// pFindings (text for the repair prompt) and pScore (0..1 judge score).
ClassMethod AccuracyGate(pJob As DTL.Data.Job, pClassName As %String, pSpec As %String, pPrimaryOutput As %String, Output pReport As %DynamicObject, Output pFindings As %String, Output pScore As %Numeric) As %String
{
	set pJob.Status = "JUDGING"
	do pJob.%Save()
	set pReport = {}
	set pReport.stage = "accuracy"
	set pFindings = "", pScore = 0
	set nl = $char(10)

	// 1 + 2: run over all inputs and collect per-input change sets.
	kill tInputs
	set n = $order(^DTL.JobInputs(pJob.JobId, ""), -1)
	if n = "" { set tInputs(1) = pJob.StreamStr(pJob.SourceHL7) }
	else { for i = 1:1:n { set tInputs(i) = $get(^DTL.JobInputs(pJob.JobId, i)) } }
	set tRun = ##class(DTL.Util.Verifier).RunAll(pClassName, .tInputs, pJob.SourceDocType)
	set pReport.runAll = tRun

	// HARD requirement: the DTL must run cleanly on every example input.
	set tBadHigh = "", tBadLow = ""
	if 'tRun.ran set tBadHigh = tBadHigh _ "- The DTL throws a runtime error on at least one of the example inputs (it must run cleanly on all of them)." _ nl
	// Coverage (anyChange) is now an ADVISORY signal, NOT a hard gate: a correct
	// transform whose changes are all conditional+untriggered (or already-matching)
	// on these example inputs legitimately changes nothing. Surface it as LOW so the
	// reviewer/LLM can sanity-check target paths, but don't fail the gate on it alone.
	if 'tRun.anyChange set tBadLow = tBadLow _ "- [LOW] The DTL produced output identical to the input for every example — no field changed. If the spec mandates changes for this message, verify the target paths are valid (a wrong path is silently ignored). If the spec's changes are all conditional and not triggered by these inputs, this is expected." _ nl

	// 3: LLM-as-judge conformance on the primary output (scoped to this DocType).
	set tJudge = ..Judge(pJob, pSpec, pJob.StreamStr(pJob.SourceHL7), pPrimaryOutput)
	set pReport.judge = tJudge
	set pScore = $select($isobject(tJudge)&&(tJudge.score'=""):+tJudge.score, 1:0)

	// Tally REAL violations by severity. The judge sometimes lists items it then
	// describes as satisfied ("...this is satisfied", "no violation here", "correct")
	// — defensively drop any entry whose detail self-identifies as a non-violation so
	// such artefacts can neither block the pass nor pollute the repair feedback.
	set tHigh = 0, tLow = 0
	if $isobject(tJudge), $isobject(tJudge.violations) {
		set it = tJudge.violations.%GetIterator()
		while it.%GetNext(.k, .v) {
			continue:'$isobject(v)
			set tDetail = v.detail, tDL = $zconvert(tDetail, "L")
			// Skip self-contradicting "actually satisfied" entries.
			if (tDL [ "this is satisfied") || (tDL [ "no violation") || (tDL [ "satisfying the rule") || (tDL [ "satisfies the rule") || (tDL [ "satisfies rule") || (tDL [ "is satisfied") continue
			set tSev = $zconvert($select(v.severity'="":v.severity, 1:"HIGH"), "U")
			if tSev = "HIGH" {
				set tHigh = tHigh + 1
				set tBadHigh = tBadHigh _ "- [HIGH] Rule not satisfied: " _ v.rule _ $select(tDetail'="":" — " _ tDetail, 1:"") _ nl
			} else {
				set tLow = tLow + 1
				set tBadLow = tBadLow _ "- [LOW] " _ v.rule _ $select(tDetail'="":" — " _ tDetail, 1:"") _ nl
			}
		}
	}
	set pReport.highCount = tHigh, pReport.lowCount = tLow
	// Feed back HIGH findings first (the real defects to fix); include LOW items only
	// as secondary context so the model fixes genuine bugs instead of churning on
	// nitpicks (which is what produced identical-candidate / plateau dead-ends).
	if tBadHigh = "" {
		set pFindings = tBadLow
	} elseif tBadLow '= "" {
		set pFindings = tBadHigh _ "Secondary (LOW — address only if it does not regress the above):" _ nl _ tBadLow
	} else {
		set pFindings = tBadHigh
	}

	// PASS when it ran everywhere and there are NO HIGH-severity violations. LOW items
	// and the advisory coverage signal do NOT block success — they were the source of
	// the never-passing plateau (the gate used to require an EMPTY violations list and
	// ignored severity entirely, so any LOW nitpick blocked SUCCESS forever).
	set tPass = tRun.ran && (tHigh = 0)
	set pReport.pass = tPass
	quit $select(tPass:"SUCCESS", 1:"MISMATCH")
}

/// Call the LLM-as-judge and return the parsed verdict object (or "" on failure).
/// The judge is a SEPARATE short call (not part of the build transcript) so it
/// doesn't pollute the build conversation or get cached with it.
ClassMethod Judge(pJob As DTL.Data.Job, pSpec As %String, pInput As %String, pOutput As %String) As %DynamicObject
{
	set tReq = ##class(DTL.Msg.LLMRequest).%New()
	set tReq.JobId = pJob.JobId
	set tReq.Attempt = pJob.AttemptsUsed + 1
	set tReq.Provider = pJob.Provider
	set tReq.Model = pJob.Model
	set tReq.ApiKey = $get(^DTL.JobKey(pJob.JobId))
	set tReq.BedrockRegion = $get(^DTL.JobRegion(pJob.JobId))
	set tSys = ##class(DTL.Msg.ChatTurn).%New()
	set tSys.Role = "system", tSys.Content = "You are a strict, fair QA grader. You output only the requested JSON."
	do tReq.Transcript.Insert(tSys)
	set tUsr = ##class(DTL.Msg.ChatTurn).%New()
	set tUsr.Role = "user", tUsr.Content = ##class(DTL.Util.PromptBuilder).JudgePrompt(pSpec, pInput, pOutput, pJob.SourceDocType)
	do tReq.Transcript.Insert(tUsr)
	set sc = ##class(Ens.Director).CreateBusinessService("EnsLib.Testing.Service", .tSvc)
	if $$$ISERR(sc) quit ""
	set sc = tSvc.SendRequestSync(..#LLMTARGET, tReq, .tResp, 600)
	if $$$ISERR(sc) || '$isobject(tResp) quit ""
	// Account for the judge's tokens/cost in the running totals (transparency).
	set tInTok = +tResp.InputTokens, tOutTok = +tResp.OutputTokens
	set tCost = ##class(DTL.Util.Pricing).Cost(pJob.Model, tInTok, tOutTok)
	do ..AddJudgeTurn(pJob, pJob.StreamStr(tResp.RawContent), tInTok, tOutTok, tCost)
	quit ..ParseJSONBlock(pJob.StreamStr(tResp.RawContent))
}

/// COVERAGE CHECK (deterministic, fully generic — no segment names baked in). Given
/// the specification markdown and the produced plan text, return a newline list of
/// the spec rule lines whose FIELD TOKEN does not appear anywhere in the plan ("" if
/// the plan covers them all). We only enforce rules that carry a concrete HL7 field
/// reference (a token like SEG.field / SEG-field, e.g. OBX.2, MSH.12, PID.3.4):
/// general prose ("support HL7 v2.4") has no field token and isn't a per-field plan
/// item, so it's not flagged. A rule is "covered" if ANY field token it mentions
/// appears in the plan (token match is whitespace/punctuation tolerant). This is what
/// catches a conditional/runtime rule (e.g. OBX.2) being silently dropped.
/// pSegSet (optional): ",MSH,PID,OBX,…," of segments that exist in THIS message's
/// structure (from HL7Schema.SegmentSet). When supplied, a rule is only enforced if at
/// least one of its field tokens' SEGMENTS is in that set — so rules for OTHER message
/// types (e.g. ACK/SIU/REF segments absent from an ORU_R01) are NOT demanded. When
/// empty, all field-token rules are enforced (back-compat).
ClassMethod UncoveredRules(pSpec As %String, pPlan As %String, pSegSet As %String = "") As %String
{
	set nl = $char(10)
	// Build the SET of field tokens the plan covers (exact membership — NOT substring,
	// so "OBX.1" is not falsely matched by "OBX.11").
	kill tPlanSet, tPlanToks
	set nP = ..FieldTokens(pPlan, .tPlanToks)
	for p = 1:1:nP { set tPlanSet(tPlanToks(p)) = 1 }
	set tOut = "", tShown = 0
	set tN = $length(pSpec, nl)
	for i = 1:1:tN {
		set tLine = $zstrip($piece(pSpec, nl, i), "<>W")
		continue:tLine=""
		// Only consider rule bullets ("- ...") — headings/blank/prose are not plan items.
		continue:$extract(tLine)'="-"
		set tRule = $zstrip($extract(tLine, 2, *), "<>W")
		continue:tRule=""
		// Extract every field token in the rule (SEG.field…). No token => not a per-field
		// rule (general guidance like "support HL7 v2.4") => don't enforce coverage on it.
		kill tToks
		set nTok = ..FieldTokens(tRule, .tToks)
		continue:nTok=0
		// SCOPE: if we know this message's segments, only enforce rules whose segment
		// exists here — skip rules that target other message types' segments.
		if pSegSet '= "" {
			set tInScope = 0
			for t = 1:1:nTok { if pSegSet [ ("," _ $piece(tToks(t), ".", 1) _ ",") { set tInScope = 1  quit } }
			continue:'tInScope
		}
		// Covered if ANY of its tokens is in the plan's token set (exact match).
		set tCovered = 0
		for t = 1:1:nTok { if $data(tPlanSet(tToks(t))) { set tCovered = 1  quit } }
		continue:tCovered
		set tShown = tShown + 1
		quit:tShown>40   // safety cap on feedback size
		set tOut = tOut _ "- " _ tRule _ nl
	}
	quit tOut
}

/// Generic test: does a rule line state a CONDITIONAL REQUIREMENT (a field that is
/// required/mandated WHEN some condition holds)? Matches phrasings like "required if
/// …", "required when …", "must … when/if …", "if … (is/are) (required|present|
/// filled|populated)", "when … (filled|present|populated)". No segment names baked in.
ClassMethod IsConditionalReq(pRule As %String) As %Boolean
{
	set r = $zconvert(pRule, "L")
	// Must mention a requirement AND a condition keyword.
	set tReq = (r [ "required") || (r [ "must ") || (r [ "mandatory") || (r [ "shall ")
	set tCond = (r [ "if ") || (r [ "when ") || (r [ "whenever ") || (r [ "unless ")
	quit (tReq && tCond)
}

/// CONDITIONAL-REQUIREMENT CHECK (deterministic, generic). Return the spec rule lines
/// that are CONDITIONAL REQUIREMENTS but appear in the plan as 'passed through
/// unchanged / no transform' — i.e. a runtime rule the model wrongly downgraded to a
/// no-op. Matched by field token (same scheme as UncoveredRules); scoped to pSegSet
/// when given. "" if none are misclassified.
ClassMethod MisclassifiedConditionals(pSpec As %String, pPlan As %String, pSegSet As %String = "") As %String
{
	set nl = $char(10)
	// Index the plan lines by field token, recording whether each is marked pass-through.
	kill tPassTok
	set pN = $length(pPlan, nl)
	for i = 1:1:pN {
		set tPL = $piece(pPlan, nl, i)
		continue:tPL=""
		set tIsPass = ($zconvert(tPL, "L") [ "passed through") || ($zconvert(tPL, "L") [ "no transform")
		continue:'tIsPass
		kill tPT
		set nT = ..FieldTokens(tPL, .tPT)
		for t = 1:1:nT { set tPassTok(tPT(t)) = 1 }
	}
	set tOut = "", tShown = 0
	set sN = $length(pSpec, nl)
	for i = 1:1:sN {
		set tLine = $zstrip($piece(pSpec, nl, i), "<>W")
		continue:$extract(tLine)'="-"
		set tRule = $zstrip($extract(tLine, 2, *), "<>W")
		continue:tRule=""
		continue:'..IsConditionalReq(tRule)
		kill tToks
		set nTok = ..FieldTokens(tRule, .tToks)
		continue:nTok=0
		// scope to this message type if known
		if pSegSet '= "" {
			set tInScope = 0
			for t = 1:1:nTok { if pSegSet [ ("," _ $piece(tToks(t), ".", 1) _ ",") { set tInScope = 1  quit } }
			continue:'tInScope
		}
		// flagged if ANY of its tokens is marked pass-through in the plan
		set tBad = 0
		for t = 1:1:nTok { if $data(tPassTok(tToks(t))) { set tBad = 1  quit } }
		continue:'tBad
		set tShown = tShown + 1
		quit:tShown>40
		set tOut = tOut _ "- " _ tRule _ nl
	}
	quit tOut
}

/// Pull canonical "SEG.field" tokens out of a piece of text into tToks(n), returning
/// the count. Matches an HL7 field reference: a 2-4 char segment name (first char a
/// letter) followed by a '.' or '-' separator and a field number — e.g. "OBX.2",
/// "MSH-12", "PID.3.4" (-> PID.3). The separator MUST be '.' or '-' (NOT a space) so
/// ordinary prose like "version 2.4" does not yield a bogus token. Generic: segments
/// are discovered from the text, never a hardcoded list.
ClassMethod FieldTokens(pText As %String, Output pToks) As %Integer
{
	kill pToks
	set n = 0, tU = $zconvert(pText, "U")
	set tLen = $length(tU)
	set i = 1
	while i <= tLen {
		set c = $extract(tU, i)
		// A segment name starts with a letter; grab a run of up to 4 alnum chars.
		if c?1A {
			set tSeg = c, j = i + 1
			while (j <= tLen) && ($extract(tU, j)?1AN) && ($length(tSeg) < 4) { set tSeg = tSeg _ $extract(tU, j), j = j + 1 }
			// HL7 segment name is 2-4 chars. Require a '.' or '-' separator then a number.
			if ($length(tSeg) >= 2) {
				set tSep = $extract(tU, j)
				if (tSep = ".") || (tSep = "-") {
					set k = j + 1, tNum = ""
					while (k <= tLen) && ($extract(tU, k)?1N) { set tNum = tNum _ $extract(tU, k), k = k + 1 }
					if tNum '= "" {
						set n = n + 1, pToks(n) = tSeg _ "." _ +tNum
						set i = k
						continue
					}
				}
			}
			set i = j
			continue
		}
		set i = i + 1
	}
	quit n
}

/// Parse a strict-JSON object out of an LLM reply that may be wrapped in prose or a
/// ```json fence. Returns the %DynamicObject or "" if none parses.
ClassMethod ParseJSONBlock(pReply As %String) As %DynamicObject
{
	set tTxt = pReply
	// Strip a leading ```json / ``` fence if present.
	if tTxt [ "```" {
		set tOpen = $find(tTxt, "```")
		set tNL = $find(tTxt, $char(10), tOpen)
		if tNL = 0 set tNL = tOpen
		set tClose = $find(tTxt, "```", tNL)
		if tClose > 0 set tTxt = $extract(tTxt, tNL, tClose - 4)
	}
	// Slice to the outermost { ... }.
	set tS = $find(tTxt, "{") - 1
	set tE = 0
	for i = $length(tTxt):-1:1 { if $extract(tTxt, i) = "}" set tE = i quit }
	if (tS <= 0) || (tE = 0) || (tE < tS) quit ""
	set tJsonStr = $extract(tTxt, tS, tE)
	try { return ##class(%DynamicAbstractObject).%FromJSON(tJsonStr) } catch { return "" }
}

/// True if the job's accumulated cost has crossed its CostCap (0 = no cap).
ClassMethod OverCostCap(pJob As DTL.Data.Job) As %Boolean
{
	quit:+pJob.CostCap'>0 0
	set tU = pJob.UsageSummary()
	quit (+tU.cost >= +pJob.CostCap)
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
		set tReply = ..CallLLM(pJob, .tSession, .tErr, 0, .tInTok, .tOutTok, .tCost)
		set pJob.SessionId = tSession
		if tReply = "" { set pJob.LastError = "LLM correction failed: " _ tErr  do pJob.%Save()  quit }
		set tClassSrc = ##class(DTL.Util.Extractor).Extract(tReply, .tCN, .tValid)
		do ..AddAssistantTurn(pJob, tClassSrc, tInTok, tOutTok, tCost)
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

/// Send the job's BUILD transcript to the LLM via a transient, fully-traced testing
/// service. Returns the RAW assistant text ("" on failure) and the session id.
/// pPlanMode=1 accepts a reply that is intentionally NOT a DTL class (plan/struct).
ClassMethod CallLLM(pJob As DTL.Data.Job, Output pSession As %String, Output pErr As %String, pPlanMode As %Boolean = 0, Output pInTok As %Integer, Output pOutTok As %Integer, Output pCost As %Numeric) As %String
{
	set pSession = "", pErr = "", pInTok = 0, pOutTok = 0, pCost = 0
	set sc = ##class(Ens.Director).CreateBusinessService("EnsLib.Testing.Service", .tSvc)
	if $$$ISERR(sc) { set pErr = $system.Status.GetErrorText(sc) quit "" }
	set tReq = ##class(DTL.Msg.LLMRequest).%New()
	set tReq.JobId = pJob.JobId
	set tReq.Attempt = pJob.AttemptsUsed + 1
	set tReq.Provider = pJob.Provider
	set tReq.Model = pJob.Model
	set tReq.ApiKey = $get(^DTL.JobKey(pJob.JobId))   // transient key, not on the Job record
	set tReq.BedrockRegion = $get(^DTL.JobRegion(pJob.JobId))
	// During spec-structuring (before the build conversation starts) send the whole
	// transcript; afterwards send only the build portion (skips the big raw spec).
	do pJob.FillTranscript(tReq, (pJob.BuildStartIndex > 1))
	set sc = tSvc.SendRequestSync(..#LLMTARGET, tReq, .tResp, 600)
	set pSession = tSvc.%SessionId
	if $$$ISERR(sc) { set pErr = $system.Status.GetErrorText(sc) quit "" }
	if '$isobject(tResp) { set pErr = "no response" quit "" }
	set pInTok = +tResp.InputTokens, pOutTok = +tResp.OutputTokens
	set pCost = ##class(DTL.Util.Pricing).Cost(pJob.Model, pInTok, pOutTok)
	set tRaw = pJob.StreamStr(tResp.RawContent)
	if (tRaw = "") {
		set pErr = $select(tResp.ErrorText'="":tResp.ErrorText, 1:"empty response")
		quit ""
	}
	quit tRaw
}

/// Append an assistant turn carrying the token/cost of the call that produced it.
ClassMethod AddAssistantTurn(pJob As DTL.Data.Job, pContent As %String, pInTok As %Integer, pOutTok As %Integer, pCost As %Numeric)
{
	set t = ##class(DTL.Msg.ChatTurn).%New()
	set t.Role = "assistant"
	set t.Content = pContent
	set t.InputTokens = +pInTok
	set t.OutputTokens = +pOutTok
	set t.Cost = +pCost
	do pJob.Transcript.Insert(t)
	set ^DTL.Usage("cost") = (+$get(^DTL.Usage("cost"))) + (+pCost)
	set ^DTL.Usage("tokens") = (+$get(^DTL.Usage("tokens"))) + (+pInTok) + (+pOutTok)
}

/// Append the LLM-judge exchange to the transcript (visible in the UI) as a
/// clearly-labelled assistant turn carrying its own token/cost, kept OUT of the
/// build conversation (it lives after the current end, but build calls only re-send
/// from BuildStartIndex..the last build turn; the judge turn is appended and then
/// the next build user-turn follows it, so we tag the content so the UI can show it
/// as a side QA call).
ClassMethod AddJudgeTurn(pJob As DTL.Data.Job, pContent As %String, pInTok As %Integer, pOutTok As %Integer, pCost As %Numeric)
{
	set t = ##class(DTL.Msg.ChatTurn).%New()
	set t.Role = "assistant"
	set t.Content = "[spec-conformance judge]" _ $char(10) _ pContent
	set t.InputTokens = +pInTok
	set t.OutputTokens = +pOutTok
	set t.Cost = +pCost
	set t.Aux = 1
	do pJob.Transcript.Insert(t)
	set ^DTL.Usage("cost") = (+$get(^DTL.Usage("cost"))) + (+pCost)
	set ^DTL.Usage("tokens") = (+$get(^DTL.Usage("tokens"))) + (+pInTok) + (+pOutTok)
}

ClassMethod SafeName(pName As %String) As %String
{
	set out = ""
	for i = 1:1:$length(pName) { set c = $extract(pName, i)  if (c?1(1A,1N)) set out = out _ c }
	if (out '= ""), '($extract(out)?1A) set out = "X" _ out
	quit $select(out'="":out, 1:"Job")
}

}
