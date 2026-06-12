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

/// Kick off concise-spec generation in the BACKGROUND and return immediately, so
/// the synchronous /concise HTTP request can't time out (504) on a large spec that
/// needs several big, slow LLM calls. Marks the doc PENDING, stashes the per-user
/// API key in a transient global (never persisted on the record), and JOBs RunJob.
/// The UI then polls GET /specs/:token until ConciseStatus becomes READY or ERROR.
ClassMethod Start(pToken As %String, pProvider As %String, pModel As %String, pApiKey As %String, pRegion As %String = "") As %Status
{
	set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pToken, .sc)
	if '$isobject(tDoc) quit $$$ERROR($$$GeneralError, "No spec '" _ pToken _ "'")
	if tDoc.Status '= "READY" quit $$$ERROR($$$GeneralError, "Spec text not extracted yet (status " _ tDoc.Status _ ").")
	// Mark PENDING up front so an immediate poll sees "in progress", not the stale
	// prior state. Clear any previous error.
	set tDoc.ConciseStatus = "PENDING", tDoc.ConciseError = ""
	do tDoc.%Save()
	// Stash the transient key/region for the spawned process (the JOB'd job has its
	// own context and can't see local vars). Keyed by token; cleared by RunJob.
	set ^DTL.ConciseKey(pToken) = $listbuild(pProvider, pModel, pApiKey, pRegion)
	// Spawn a detached background job in this namespace to do the slow work.
	job ##class(DTL.Service.SpecConcise).RunJob(pToken)
	quit $$$OK
}

/// Background entry point (JOB'd by Start). Reads the stashed provider/key, runs the
/// synchronous Generate, then clears the transient key. Errors land on the SpecDoc
/// (ConciseStatus=ERROR + ConciseError), so the polling UI always sees an outcome.
ClassMethod RunJob(pToken As %String)
{
	set tArgs = $get(^DTL.ConciseKey(pToken))
	set tProvider = $listget(tArgs, 1), tModel = $listget(tArgs, 2)
	set tKey = $listget(tArgs, 3), tRegion = $listget(tArgs, 4)
	try {
		do ..Generate(pToken, tProvider, tModel, tKey, tRegion)
	} catch ex {
		set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pToken, .sc)
		if $isobject(tDoc) {
			set tDoc.ConciseStatus = "ERROR", tDoc.ConciseError = ex.DisplayString()
			do tDoc.%Save()
		}
	}
	// Drop the transient key as soon as the work is done (don't leave secrets around).
	kill ^DTL.ConciseKey(pToken)
	quit
}

/// Generate (and verify) the concise spec for a token. Idempotent-ish: regenerates
/// on each call (the UI only calls it when ConciseStatus is not READY, or on an
/// explicit "regenerate"). Returns %Status; details land on the SpecDoc record.
/// Runs SYNCHRONOUSLY — called in-process by RunJob (background) and directly by
/// tests. The REST endpoint uses Start (async) so the HTTP request can't 504.
ClassMethod Generate(pToken As %String, pProvider As %String, pModel As %String, pApiKey As %String, pRegion As %String = "") As %Status
{
	set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pToken, .sc)
	if '$isobject(tDoc) quit $$$ERROR($$$GeneralError, "No spec '" _ pToken _ "'")
	if tDoc.Status '= "READY" quit $$$ERROR($$$GeneralError, "Spec text not extracted yet (status " _ tDoc.Status _ ").")
	set tDoc.ConciseStatus = "PENDING", tDoc.ConciseError = ""
	do tDoc.%Save()
	set tSC = $$$OK
	try {
		set tRaw = tDoc.TextStr()
		// 1) Generate the concise, grouped, referenced spec. Ask for a generous output
		// budget — a large interface document yields a large JSON object, and a low cap
		// silently truncates it mid-object (invalid JSON). If the model still reports it
		// hit the length limit, retry ONCE with a bigger budget before giving up.
		set tSys = "You reorganise interface specifications into clear, concise, grouped rule lists. You output only the requested JSON and never invent requirements."
		set tUser = ##class(DTL.Util.PromptBuilder).ConciseSpecPrompt(tRaw)
		// Token budget is INTENTIONALLY large at the specification stage — we do NOT
		// optimise tokens here; completeness matters more than cost. Start high and, if
		// the model still reports it hit the length limit, escalate further before
		// giving up. ..#SPECMAXTOKENS is the cap that almost never truncates real specs.
		set tReply = ##class(DTL.Util.LLM).Chat(pProvider, pModel, pApiKey, tSys, tUser, .tErr, pRegion, , , , ..#SPECMAXTOKENS, .tFinish)
		if (tReply '= ""), (tFinish = "length") {
			set tReply = ##class(DTL.Util.LLM).Chat(pProvider, pModel, pApiKey, tSys, tUser, .tErr, pRegion, , , , ..#SPECMAXTOKENSHI, .tFinish)
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
			// Reply came back but wasn't valid JSON — keep the raw text as the concise
			// spec (better than empty) but flag it so the user knows to review closely.
			// Distinguish a TRUNCATED reply (model hit the output-token limit -> JSON cut
			// off mid-object) from a genuine format problem, so the user knows it's a
			// size issue and not a bad spec.
			do tDoc.ConciseSpec.Clear()  do tDoc.ConciseSpec.Write(tReply)
			do tDoc.ConciseProvenance.Clear()  do tDoc.ConciseProvenance.Write("{}")
			if tFinish = "length" {
				set tDoc.ConciseError = "The specification is large and the model's reply was cut off at its output-token limit, so the JSON is incomplete. Showing the partial reply — try a model with a larger output budget, or split the document. (No per-item source links until it returns complete JSON.)"
			} else {
				set tDoc.ConciseError = "The model did not return structured JSON; showing its raw reply — review carefully (no per-item source links)."
			}
		} else {
			do ..ApplyConcise(tDoc, tJson)
			// Deterministic scoping guardrail: flag likely mis-scoped generic rules so a
			// reviewer catches them before generation silently drops them for some types.
			set tScopeWarn = ..ScopeWarnings(tJson)
			if tScopeWarn '= "" set tDoc.ConciseError = $select(tDoc.ConciseError'="":tDoc.ConciseError _ $char(10,10), 1:"") _ tScopeWarn
		}
		// 2) Verify the concise spec against the original (LLM half of verification).
		// A failure here is non-fatal: we still have a concise spec to review; record a
		// soft note rather than failing the whole generation.
		set tVer = ##class(DTL.Util.LLM).Chat(pProvider, pModel, pApiKey, "You are a strict, fair specification auditor. You output only the requested JSON.", ##class(DTL.Util.PromptBuilder).ConciseVerifyPrompt(tRaw, tDoc.ConciseStr()), .tVErr, pRegion, , , , ..#SPECMAXTOKENS)
		if tVer '= "" {
			set tVObj = ##class(DTL.Util.LLM).ParseJSON(tVer)
			if $isobject(tVObj) set tDoc.ConciseVerdict = $extract(tVObj.%ToJSON(), 1, 8000)
		} elseif (tDoc.ConciseError = "") {
			set tDoc.ConciseError = "Concise spec generated, but the automated completeness/hallucination check could not run (" _ $select(tVErr'="":tVErr, 1:"no response") _ "). Please review carefully."
		}
		set tDoc.ConciseStatus = "READY"
		do tDoc.%Save()
	} catch ex {
		set tSC = ex.AsStatus()
		set tDoc.ConciseStatus = "ERROR", tDoc.ConciseError = ex.DisplayString()
		do tDoc.%Save()
	}
	quit tSC
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
	do pDoc.ConciseSpec.Clear()  do pDoc.ConciseSpec.Write(tMd)
	do pDoc.ConciseProvenance.Clear()  do pDoc.ConciseProvenance.Write(pJson.%ToJSON())
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
