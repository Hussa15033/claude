/// Generates and verifies the CONCISE specification for an uploaded document.
/// Runs once (triggered from REST right after text extraction is READY, because the
/// per-user LLM API key lives on the request, not on the file-watcher job). The
/// concise spec is stored on the DTL.Data.SpecDoc so that re-selecting a saved spec
/// loads the concise version instead of regenerating it.
///
/// Output on the SpecDoc:
///   ConciseSpec        — clear markdown, grouped by message/segment type
///   ConciseProvenance  — JSON {title, groups:[{type,items:[{id,rule,sourceQuote,
///                        inferred}]}], ambiguities:[...]} for click-to-reference
///   ConciseVerdict     — JSON completeness/hallucination audit (LLM half of the
///                        human+LLM verification)
///   ConciseStatus      — PENDING | READY | ERROR
Class DTL.Service.SpecConcise Extends %RegisteredObject
{

/// Output-token budget for concise-spec LLM calls. Deliberately large: at the
/// specification stage we prioritise a COMPLETE structured reply over token cost,
/// so a big interface document's JSON is never silently truncated mid-object.
Parameter SPECMAXTOKENS = 65536;

/// Escalation budget used for a single retry when the model still reports it hit
/// the length limit at SPECMAXTOKENS.
Parameter SPECMAXTOKENSHI = 131072;

/// Config item (Business Process) that owns concise-spec generation off the queue.
Parameter FORGETARGET = "DTL.Proc.SpecForge";

/// Config name of the LLM operation the SpecForge host sends to directly.
Parameter LLMTARGET = "DTL.Op.LLMConnector";

/// Timeout (seconds) for a synchronous LLM call from the host.
Parameter LLMTIMEOUT = 600;

/// Kick off concise-spec generation and return immediately, so the synchronous
/// /concise HTTP request can't time out (504) on a large spec that needs big, slow
/// LLM calls. Marks the doc PENDING, then dispatches a DURABLE DTL.Msg.ConciseRequest
/// onto the production's queue. A supervised DTL.Proc.SpecForge worker processes it
/// and ALWAYS writes a terminal ConciseStatus (READY/ERROR); if the worker dies
/// mid-call, Ensemble REDELIVERS the message on recovery — so the record can never
/// hang in PENDING (the failure mode of the old detached `job` background worker).
/// The UI polls GET /specs/:token until ConciseStatus becomes READY or ERROR.
ClassMethod Start(pToken As %String, pProvider As %String, pModel As %String, pApiKey As %String, pRegion As %String = "") As %Status
{
	set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pToken, .sc)
	if '$isobject(tDoc) quit $$$ERROR($$$GeneralError, "No spec '" _ pToken _ "'")
	if tDoc.Status '= "READY" quit $$$ERROR($$$GeneralError, "Spec text not extracted yet (status " _ tDoc.Status _ ").")
	// Mark PENDING up front so an immediate poll sees "in progress", not the stale
	// prior state. ConciseStarted records that generation was actually dispatched (so the
	// UI can tell a genuinely-generating spec from one just sitting at the initial
	// PENDING). Clear any previous error.
	set tDoc.ConciseStatus = "PENDING", tDoc.ConciseStarted = 1, tDoc.ConciseError = ""
	do tDoc.%Save()
	quit ..DispatchAsync(pToken, pProvider, pModel, pApiKey, pRegion, "generate")
}

/// Build a ConciseRequest and submit it ASYNCHRONOUSLY into the production through
/// the inbound business service DTL.Svc.ApiService (the supported entry point), so
/// the HTTP request returns at once and the durable DTL.Proc.SpecForge worker does
/// the slow work — visible end-to-end in the Visual Trace
/// (ApiService -> SpecForge -> LLMConnector). If the production isn't running we
/// FALL BACK to a synchronous in-process run so the feature still works in a bare
/// test namespace rather than stranding.
ClassMethod DispatchAsync(pToken As %String, pProvider As %String, pModel As %String, pApiKey As %String, pRegion As %String, pMode As %String) As %Status
{
	if '##class(Ens.Director).IsProductionRunning() {
		// No production: run inline (synchronous) so the work still completes. Generate/
		// Verify each commit a terminal status, so this path also can't strand PENDING.
		// With no host, the LLM call falls back to DTL.Util.LLM.Chat internally.
		if pMode = "verify" quit ..Verify("", pToken, pProvider, pModel, pApiKey, pRegion)
		set tSC = ..Generate("", pToken, pProvider, pModel, pApiKey, pRegion)
		if $$$ISOK(tSC) {
			set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pToken, .sc)
			if $isobject(tDoc), tDoc.ConciseStatus = "READY" {
				set tDoc.ConciseVerifyStatus = "PENDING"  do tDoc.%Save()
				do ..Verify("", pToken, pProvider, pModel, pApiKey, pRegion)
			}
		}
		quit tSC
	}
	set tSC = ##class(Ens.Director).CreateBusinessService("DTL.Svc.ApiService", .tSvc)
	quit:$$$ISERR(tSC) tSC
	set tReq = ##class(DTL.Msg.ConciseRequest).%New()
	set tReq.Token = pToken, tReq.Provider = pProvider, tReq.Model = pModel
	set tReq.ApiKey = pApiKey, tReq.Region = pRegion, tReq.Mode = pMode
	quit tSvc.SubmitConcise(tReq)
}

/// Issue one LLM call. When pHost is a running interoperability host (the SpecForge
/// BP), send the request DIRECTLY from it (..SendRequestSync) so the call is a child
/// message of that host in the Visual Trace. With no host (the no-production inline
/// fallback / tests), use the one-shot DTL.Util.LLM.Chat. Returns the raw reply ("" on
/// failure, pErr set) plus finish reason byref. Centralised so Generate and Verify
/// share the exact same routing.
/// pCategory/pRefToken/pLabel feed the cost ledger: every spec LLM call (including a
/// length-escalation retry) is recorded as one row, RefKind="spec", so per-spec cost
/// is the sum of these rows. Token usage was previously DISCARDED on this path — that
/// is the bug that made spec costs invisible and the grand total too low. We record
/// here, at the single chokepoint both Generate and Verify go through, so the dollar
/// amount comes from the same DTL.Util.Pricing formula the DTL side uses.
/// pCachedPrefix is the large STATIC system block (the raw source document) that is
/// IDENTICAL across the generate call, the audit call, the length-escalation retry and
/// any regeneration — it is flagged as a prompt-cache breakpoint so it is billed once
/// and re-read from cache thereafter (the spec doc is the dominant token cost on this
/// path). pPersona is the small role line; pUser is the per-call task instruction.
ClassMethod CallLLM(pHost As Ens.Host, pProvider As %String, pModel As %String, pApiKey As %String, pCachedPrefix As %String, pPersona As %String, pUser As %String, pRegion As %String, pMaxTokens As %Integer, Output pErr As %String, Output pFinish As %String, pCategory As %String = "", pRefToken As %String = "", pLabel As %String = "") As %String
{
	set pErr = "", pFinish = "", tInTok = 0, tOutTok = 0
	set tReq = ##class(DTL.Util.LLM).BuildRequestCached(pProvider, pModel, pApiKey, pCachedPrefix, pPersona, pUser, pRegion, pMaxTokens)
	if '$isobject(pHost) {
		set tRaw = ##class(DTL.Util.LLM).ChatReq(tReq, .pErr, .tInTok, .tOutTok, , .pFinish)
	} else {
		set tSC = pHost.SendRequestSync(..#LLMTARGET, tReq, .tResp, ..#LLMTIMEOUT)
		if $$$ISERR(tSC) { set pErr = $system.Status.GetErrorText(tSC) quit "" }
		if '$isobject(tResp) { set pErr = "no response" quit "" }
		set pFinish = tResp.FinishReason
		set tInTok = +tResp.InputTokens, tOutTok = +tResp.OutputTokens
		set tRaw = ##class(DTL.Data.Job).StreamStr(tResp.RawContent)
		if tRaw = "" { set pErr = $select(tResp.ErrorText'="":tResp.ErrorText, 1:"empty response") }
	}
	// Record the call's cost (only when the provider reported usage). Best-effort.
	if (pCategory '= ""), ((+tInTok) || (+tOutTok)) {
		do ##class(DTL.Util.Cost).Record(pCategory, "spec", pRefToken, pLabel, pModel, tInTok, tOutTok)
	}
	quit tRaw
}

/// Generate (and verify) the concise spec for a token. Idempotent-ish: regenerates
/// on each call (the UI only calls it when ConciseStatus is not READY, or on an
/// explicit "regenerate"). Returns %Status; details land on the SpecDoc record.
/// Runs SYNCHRONOUSLY — called in-process by the DTL.Proc.SpecForge queue worker and
/// directly by tests. The REST endpoint uses Start (async dispatch onto that durable
/// BP) so the HTTP request can't 504 and the work can never strand at PENDING.
ClassMethod Generate(pHost As Ens.Host, pToken As %String, pProvider As %String, pModel As %String, pApiKey As %String, pRegion As %String = "") As %Status
{
	set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pToken, .sc)
	if '$isobject(tDoc) quit $$$ERROR($$$GeneralError, "No spec '" _ pToken _ "'")
	if tDoc.Status '= "READY" quit $$$ERROR($$$GeneralError, "Spec text not extracted yet (status " _ tDoc.Status _ ").")
	set tDoc.ConciseStatus = "PENDING", tDoc.ConciseStarted = 1, tDoc.ConciseError = ""
	do tDoc.%Save()
	set tSC = $$$OK
	try {
		set tRaw = tDoc.TextStr()
		// 1) Generate the concise, grouped, referenced spec. Ask for a generous output
		// budget — a large interface document yields a large JSON object, and a low cap
		// silently truncates it mid-object (invalid JSON). If the model still reports it
		// hit the length limit, retry ONCE with a bigger budget before giving up.
		set tSys = "You reorganise interface specifications into clear, concise, grouped rule lists. You output only the requested JSON and never invent requirements."
		// The source document goes in a CACHEABLE system prefix (shared, byte-identical,
		// with the audit call below + the length-retry + any regeneration); the task
		// instructions go in the user message. Caches the dominant token cost.
		set tPrefix = ##class(DTL.Util.PromptBuilder).SpecSourcePrefix(tRaw)
		set tUser = ##class(DTL.Util.PromptBuilder).ConciseSpecPrompt(tRaw)
		// Token budget is INTENTIONALLY large at the specification stage — we do NOT
		// optimise tokens here; completeness matters more than cost. Start high and, if
		// the model still reports it hit the length limit, escalate further before
		// giving up. ..#SPECMAXTOKENS is the cap that almost never truncates real specs.
		set tGenLabel = "Generation of specification " _ $select(tDoc.FileName'="":tDoc.FileName, 1:pToken)
		set tReply = ..CallLLM(pHost, pProvider, pModel, pApiKey, tPrefix, tSys, tUser, pRegion, ..#SPECMAXTOKENS, .tErr, .tFinish, "spec.generate", pToken, tGenLabel)
		if (tReply '= ""), (tFinish = "length") {
			set tReply = ..CallLLM(pHost, pProvider, pModel, pApiKey, tPrefix, tSys, tUser, pRegion, ..#SPECMAXTOKENSHI, .tErr, .tFinish, "spec.generate", pToken, tGenLabel)
		}
		if tReply = "" {
			// LLM call failed (bad key, rate limit, bad model, transport). Record the
			// descriptive provider error AND return it as a real error %Status so the
			// REST layer responds non-2xx and the UI surfaces it (don't silently leave
			// an empty concise spec).
			set tMsg = $select(tErr'="":tErr, 1:"the model returned no content")
			set tDoc.ConciseStatus = "ERROR", tDoc.ConciseError = tMsg
			do tDoc.%Save()
			set tSC = $$$ERROR($$$GeneralError, "Concise-spec generation failed: " _ tMsg)
			quit
		}
		set tJson = ##class(DTL.Util.LLM).ParseJSON(tReply)
		if '$isobject(tJson) {
			// Reply came back but wasn't valid JSON — almost always the model hit its
			// OUTPUT-TOKEN LIMIT and the JSON was cut off mid-object. A truncated/invalid
			// concise spec must NOT be usable (the user explicitly must not build from it):
			// mark it ERROR so review/approve are blocked. Keep the raw reply in ConciseSpec
			// so the UI can offer a collapsed "view raw reply" for diagnosis, but with empty
			// provenance and an ERROR status it cannot be approved or fed to the build.
			do tDoc.ConciseSpec.Clear()  do tDoc.ConciseSpec.Write(tReply)
			do tDoc.ConciseProvenance.Clear()  do tDoc.ConciseProvenance.Write("{}")
			set tDoc.ConciseStatus = "ERROR"
			if tFinish = "length" {
				set tDoc.ConciseError = "The model's reply was cut off at its output-token limit, so the specification JSON is incomplete (truncated). This spec cannot be used. Try a model with a larger output budget (e.g. Claude Sonnet/Opus instead of Haiku) for the Concise-spec model, or split the document, then regenerate."
			} else {
				set tDoc.ConciseError = "The model did not return valid, complete JSON for the specification (likely truncated at the output-token limit). This spec cannot be used. Try a model with a larger output budget for the Concise-spec model, then regenerate."
			}
			do tDoc.%Save()
			set tSC = $$$ERROR($$$GeneralError, "Concise-spec generation produced invalid/truncated JSON.")
			quit
		} else {
			// ApplyConcise also folds the deterministic SCOPE FINDINGS (structured, not a
			// prose blob) into the provenance JSON, so the UI can render them as actionable
			// cards and let the reviewer fix/move rules — see ScopeFindings. We deliberately
			// no longer append a text warning to ConciseError (that field is for real errors).
			do ..ApplyConcise(tDoc, tJson)
		}
		// Generation done -> the concise spec is READY and USABLE NOW. The completeness/
		// faithfulness AUDIT ("judge") is a SEPARATE, OPTIONAL phase (see Verify) that runs
		// after this and updates ConciseVerifyStatus/ConciseVerdict independently. It must
		// NEVER gate or block the spec: previously verify ran inline before READY, so if the
		// background job died during the (large, slow) verify call the UI polled PENDING
		// forever. Now READY is committed the moment generation succeeds.
		set tDoc.ConciseStatus = "READY"
		set tDoc.ConciseVerifyStatus = "NONE"
		do tDoc.%Save()
	} catch ex {
		set tSC = ex.AsStatus()
		set tDoc.ConciseStatus = "ERROR", tDoc.ConciseError = ex.DisplayString()
		do tDoc.%Save()
	}
	quit tSC
}

/// SECONDARY AUDIT ("judge") — completeness + faithfulness of the concise spec vs the
/// original. Runs AFTER Generate, never blocks it. Sets ConciseVerifyStatus PENDING
/// while running, then READY (verdict in ConciseVerdict) or ERROR. Safe to call only
/// when a concise spec already exists; returns immediately otherwise. A failure here
/// is non-fatal — the concise spec stays usable.
ClassMethod Verify(pHost As Ens.Host, pToken As %String, pProvider As %String, pModel As %String, pApiKey As %String, pRegion As %String = "") As %Status
{
	set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pToken, .sc)
	if '$isobject(tDoc) quit $$$ERROR($$$GeneralError, "No spec '" _ pToken _ "'")
	if $zstrip(tDoc.ConciseStr(), "<>W") = "" quit $$$ERROR($$$GeneralError, "No concise spec to verify yet.")
	set tDoc.ConciseVerifyStatus = "PENDING"
	do tDoc.%Save()
	set tSC = $$$OK
	try {
		set tRaw = tDoc.TextStr()
		set tVerLabel = "Review (audit) of specification " _ $select(tDoc.FileName'="":tDoc.FileName, 1:pToken)
		// Same cacheable source-document prefix as generation, so the audit re-reads the
		// (identical) document from cache instead of paying full input price again.
		set tVPrefix = ##class(DTL.Util.PromptBuilder).SpecSourcePrefix(tRaw)
		set tVer = ..CallLLM(pHost, pProvider, pModel, pApiKey, tVPrefix, "You are a strict, fair specification auditor. You output only the requested JSON.", ##class(DTL.Util.PromptBuilder).ConciseVerifyPrompt(tRaw, tDoc.ConciseStr()), pRegion, ..#SPECMAXTOKENS, .tVErr, .tVFinish, "spec.verify", pToken, tVerLabel)
		if tVer '= "" {
			set tVObj = ##class(DTL.Util.LLM).ParseJSON(tVer)
			if $isobject(tVObj) {
				set tDoc.ConciseVerdict = $extract(tVObj.%ToJSON(), 1, 8000)
				set tDoc.ConciseVerifyStatus = "READY"
			} else {
				set tDoc.ConciseVerifyStatus = "ERROR"
				set tDoc.ConciseError = $select(tDoc.ConciseError'="":tDoc.ConciseError _ $char(10,10), 1:"") _ "The audit reply was not valid JSON — review the concise spec manually."
			}
		} else {
			set tDoc.ConciseVerifyStatus = "ERROR"
			set tDoc.ConciseError = $select(tDoc.ConciseError'="":tDoc.ConciseError _ $char(10,10), 1:"") _ "The completeness/faithfulness check could not run (" _ $select(tVErr'="":tVErr, 1:"no response") _ "). Review the concise spec manually."
		}
		do tDoc.%Save()
	} catch ex {
		set tSC = ex.AsStatus()
		set tDoc.ConciseVerifyStatus = "ERROR", tDoc.ConciseError = ex.DisplayString()
		do tDoc.%Save()
	}
	quit tSC
}

/// Start the audit off the durable queue (so the /verify HTTP request returns at
/// once). Same architecture as Start: a supervised, redeliverable DTL.Proc.SpecForge
/// worker runs the audit and always writes a terminal ConciseVerifyStatus.
ClassMethod StartVerify(pToken As %String, pProvider As %String, pModel As %String, pApiKey As %String, pRegion As %String = "") As %Status
{
	set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pToken, .sc)
	if '$isobject(tDoc) quit $$$ERROR($$$GeneralError, "No spec '" _ pToken _ "'")
	if $zstrip(tDoc.ConciseStr(), "<>W") = "" quit $$$ERROR($$$GeneralError, "No concise spec to verify yet.")
	set tDoc.ConciseVerifyStatus = "PENDING"
	do tDoc.%Save()
	quit ..DispatchAsync(pToken, pProvider, pModel, pApiKey, pRegion, "verify")
}

/// Mark the audit as deliberately SKIPPED by the user (proceed without judging).
ClassMethod SkipVerify(pToken As %String) As %Status
{
	set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pToken, .sc)
	if '$isobject(tDoc) quit $$$ERROR($$$GeneralError, "No spec '" _ pToken _ "'")
	set tDoc.ConciseVerifyStatus = "SKIPPED"
	do tDoc.%Save()
	quit $$$OK
}

/// Render the concise JSON into reviewer-facing markdown (grouped by type) + store
/// the structured provenance for the click-to-reference UI.
ClassMethod ApplyConcise(pDoc As DTL.Data.SpecDoc, pJson As %DynamicObject)
{
	set nl = $char(10)
	set tMd = ""
	if pJson.title '= "" set tMd = "# " _ pJson.title _ nl _ nl
	if $isobject(pJson.groups) {
		set it = pJson.groups.%GetIterator()
		while it.%GetNext(.gk, .g) {
			continue:'$isobject(g)
			set tMd = tMd _ "## " _ $select(g.type'="":g.type, 1:"General") _ nl
			if $isobject(g.items) {
				set it2 = g.items.%GetIterator()
				while it2.%GetNext(.ik, .item) {
					continue:'$isobject(item)
					// Render the message-type scope inline so it survives into the approved
					// spec, the plan and the judge. "*" (all types) is left implicit; a
					// narrowed scope is shown so a generic rule wrongly pinned to one type
					// is visible to the reviewer.
					set tScope = ..AppliesToText(item.appliesTo)
					set tMd = tMd _ "- " _ item.rule _ tScope _ $select(''item.inferred:"  _(inferred)_", 1:"") _ nl
				}
			}
			set tMd = tMd _ nl
		}
	}
	if $isobject(pJson.ambiguities), pJson.ambiguities.%Size() > 0 {
		set tMd = tMd _ "## Ambiguities / decisions needed" _ nl
		set it3 = pJson.ambiguities.%GetIterator()
		while it3.%GetNext(.ak, .a) {
			// An ambiguity may be a plain string (legacy) or an object
			// {question, options:[...]} (so the reviewer gets choices).
			if $isobject(a) {
				set tQ = a.question
				set tMd = tMd _ "- " _ tQ _ nl
				if $isobject(a.options), a.options.%Size() > 0 {
					set ito = a.options.%GetIterator()
					while ito.%GetNext(.ok, .opt) { set tMd = tMd _ "  - option: " _ opt _ nl }
				}
			} else {
				set tMd = tMd _ "- " _ a _ nl
			}
		}
	}
	// Attach the deterministic SCOPE FINDINGS as STRUCTURED data on the provenance, so
	// the UI can render actionable cards (and let the reviewer fix/move a rule) instead
	// of parsing a prose blob. Shape: scopeFindings:[{groupIndex,itemIndex,id,segment,
	// kind,scopedTo,rule,message}]. kind = "NARROWED" (generic seg pinned to specific
	// type[s]) | "NOSCOPE" (no appliesTo at all). Empty array when nothing looks wrong.
	set pJson.scopeFindings = ..ScopeFindings(pJson)
	do pDoc.ConciseSpec.Clear()  do pDoc.ConciseSpec.Write(tMd)
	do pDoc.ConciseProvenance.Clear()  do pDoc.ConciseProvenance.Write(pJson.%ToJSON())
}

/// STRUCTURED scope findings (the machine-readable form of ScopeWarnings). Returns a
/// %DynamicArray of finding objects the UI renders as cards and can act on. Same
/// heuristics as ScopeWarnings: a rule on a generic/shared segment (MSH/PID/PV1/PV2/
/// NTE/EVN) narrowed to specific message type(s) is suspicious (kind=NARROWED); a rule
/// with no message-type scope at all is flagged (kind=NOSCOPE). Each finding carries
/// the group+item index so the UI can locate and edit the exact item.
ClassMethod ScopeFindings(pJson As %DynamicObject) As %DynamicArray
{
	set tOut = []
	quit:'$isobject(pJson) tOut
	quit:'$isobject(pJson.groups) tOut
	set tGeneric = ",MSH,PID,PV1,PV2,NTE,EVN,"
	set gi = -1
	set git = pJson.groups.%GetIterator()
	while git.%GetNext(.gk, .g) {
		set gi = gi + 1
		continue:'$isobject(g)
		set tType = $zconvert(g.type, "U")
		set tSeg = tType
		if tSeg [ "/" set tSeg = $zstrip($piece(tSeg, "/", $length(tSeg, "/")), "<>W")
		set tSeg = $piece(tSeg, " ", 1)
		set tIsGeneric = (tGeneric [ ("," _ tSeg _ ","))
		continue:'$isobject(g.items)
		set ii = -1
		set iit = g.items.%GetIterator()
		while iit.%GetNext(.ik, .item) {
			set ii = ii + 1
			continue:'$isobject(item)
			set tHasWild = 0, tNarrow = "", tCount = 0
			if $isobject(item.appliesTo) {
				set ait = item.appliesTo.%GetIterator()
				while ait.%GetNext(.ak, .av) {
					set av = $zstrip($select($isobject(av):"", 1:av), "<>W")
					continue:av=""
					set tCount = tCount + 1
					if av = "*" set tHasWild = 1
					else  set tNarrow = tNarrow _ $select(tNarrow'="":", ", 1:"") _ av
				}
			}
			set tKind = ""
			if tIsGeneric, 'tHasWild, tNarrow '= "" {
				set tKind = "NARROWED"
				set tMsg = tSeg _ " is a shared segment, so this rule likely applies to ALL message types — but it is scoped only to " _ tNarrow _ "."
			} elseif tCount = 0 {
				set tKind = "NOSCOPE"
				set tMsg = "This rule has no message-type scope (it will be treated as applying to all types). Confirm that is intended."
			}
			continue:tKind=""
			set tF = {}
			set tF.groupIndex = gi, tF.itemIndex = ii
			set tF.id = item.id
			set tF.segment = tSeg
			set tF.kind = tKind
			set tF.scopedTo = tNarrow
			set tF.rule = item.rule
			set tF.message = tMsg
			do tOut.%Push(tF)
		}
	}
	quit tOut
}

/// Render an item's message-type scope as an inline markdown tag. The wildcard
/// "*" (or an empty/absent value) means ALL message types and is left implicit
/// (no tag) to keep the spec clean; a NARROWED scope is shown explicitly as
/// "  _(applies to: ADT^A01, ORU^R01)_" so it travels with the rule into the plan
/// and the judge, and a wrongly-narrowed generic rule is visible to the reviewer.
ClassMethod AppliesToText(pAppliesTo As %DynamicArray) As %String
{
	quit:'$isobject(pAppliesTo) ""
	set tList = "", tWild = 0
	set it = pAppliesTo.%GetIterator()
	while it.%GetNext(.k, .v) {
		set v = $zstrip($select($isobject(v):"", 1:v), "<>W")
		continue:v=""
		if v = "*" set tWild = 1  quit
		set tList = tList _ $select(tList'="":", ", 1:"") _ v
	}
	quit:tWild ""
	quit:tList="" ""
	quit "  _(applies to: " _ tList _ ")_"
}

/// DETERMINISTIC scoping guardrail (no LLM). Inspect the concise JSON and return a
/// human-readable list of likely SCOPING MISTAKES, so a generic segment rule that
/// the model wrongly pinned to a single message type (which would be silently
/// dropped when a DTL is built for a different type) is caught on EVERY spec rather
/// than hoped away. Heuristics, conservative (warn, don't block):
///   - A rule on a clearly GENERIC/shared segment (MSH/PID/PV1/NTE/OBX/OBR/ORC) whose
///     appliesTo names specific message type(s) instead of "*" — generic header/demographic
///     rules almost always apply to all types; a single-type scope is suspicious.
///   - appliesTo missing/empty on an item (ambiguous scope — defaulted to all, flagged
///     so the reviewer confirms).
/// Returns "" when nothing looks wrong.
ClassMethod ScopeWarnings(pJson As %DynamicObject) As %String
{
	quit:'$isobject(pJson) ""
	quit:'$isobject(pJson.groups) ""
	set nl = $char(10), tOut = "", tN = 0
	// Segments whose rules are, in HL7, shared across message types.
	set tGeneric = ",MSH,PID,PV1,PV2,NTE,EVN,"
	set git = pJson.groups.%GetIterator()
	while git.%GetNext(.gk, .g) {
		continue:'$isobject(g)
		set tType = $zconvert(g.type, "U")
		// Derive the bare segment name from the group type (e.g. "MSH" from "ADT^A01 / MSH").
		set tSeg = tType
		if tSeg [ "/" set tSeg = $zstrip($piece(tSeg, "/", $length(tSeg, "/")), "<>W")
		set tSeg = $piece(tSeg, " ", 1)
		set tIsGeneric = (tGeneric [ ("," _ tSeg _ ","))
		continue:'$isobject(g.items)
		set iit = g.items.%GetIterator()
		while iit.%GetNext(.ik, .item) {
			continue:'$isobject(item)
			set tHasWild = 0, tNarrow = "", tCount = 0
			if $isobject(item.appliesTo) {
				set ait = item.appliesTo.%GetIterator()
				while ait.%GetNext(.ak, .av) {
					set av = $zstrip($select($isobject(av):"", 1:av), "<>W")
					continue:av=""
					set tCount = tCount + 1
					if av = "*" set tHasWild = 1
					else  set tNarrow = tNarrow _ $select(tNarrow'="":", ", 1:"") _ av
				}
			}
			set tRuleTxt = $extract(item.rule, 1, 90)
			// (1) Generic segment rule narrowed to specific type(s) -> suspicious.
			if tIsGeneric, 'tHasWild, tNarrow '= "" {
				set tN = tN + 1
				set tOut = tOut _ "- " _ tSeg _ " rule scoped to '" _ tNarrow _ "' but " _ tSeg _ " is a shared segment — it likely applies to ALL message types (use *). Rule: " _ tRuleTxt _ nl
			}
			// (2) No scope at all -> ambiguous (treated as all; confirm).
			elseif tCount = 0 {
				set tN = tN + 1
				set tOut = tOut _ "- No message-type scope on rule (assumed: all types). Rule: " _ tRuleTxt _ nl
			}
		}
	}
	quit:tN=0 ""
	quit "Scoping check flagged " _ tN _ " item(s) that may be mis-scoped (generic rules should apply to all message types). Review the 'applies to' tags:" _ nl _ tOut
}

}
