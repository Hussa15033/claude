/// Business Process that generates / audits the CONCISE specification for an
/// uploaded document, off the production's DURABLE queue.
///
/// This replaces the old detached-`job` background worker. The problem with the
/// detached job was that it was UNSUPERVISED: a slow or large LLM reply (e.g. a big
/// spec through Bedrock claude-opus at a 64K output budget), a recycled CSP worker,
/// or any process death left the DTL.Data.SpecDoc stranded at ConciseStatus=PENDING
/// forever — and the produced reply was orphaned because an LLMResponse carries no
/// token to re-correlate it. The UI then spun indefinitely.
///
/// A queued <class>DTL.Msg.ConciseRequest</class> is DURABLE: it is persisted before
/// the HTTP request returns, a pooled BP worker always processes it and ALWAYS
/// writes a terminal ConciseStatus (READY or ERROR), and if a worker dies mid-call
/// Ensemble REDELIVERS the message when the production recovers. So generation can
/// never hang in PENDING — it either completes, fails with a real message, or is
/// retried automatically. This is the same async-onto-the-production pattern the
/// DTL build jobs already use (DTL.Service.JobManager.DispatchAsync ->
/// DTL.Proc.Orchestrator); the actual LLM work still flows through
/// DTL.Service.SpecConcise (Generate/Verify), so the prompt/parse logic is unchanged.
Class DTL.Proc.SpecForge Extends Ens.BusinessProcess [ ClassType = persistent ]
{

/// Single synchronous step — the whole concise pipeline runs in-process here (it
/// internally makes its own synchronous LLM calls via DTL.Util.LLM, which already
/// route through the LLMConnector operation). No extra messaging hops needed; the
/// value of this BP is the DURABLE, SUPERVISED, REDELIVERABLE envelope around it.
Method OnRequest(pRequest As DTL.Msg.ConciseRequest, Output pResponse As Ens.Response) As %Status
{
	set pResponse = ##class(Ens.Response).%New()
	set tToken = pRequest.Token
	try {
		// Pass $this as the host so SpecConcise issues the LLM call via ..SendRequestSync
		// FROM this process — the call then shows as a child message of SpecForge in the
		// Visual Trace (SpecForge -> DTL.Op.LLMConnector -> SpecForge).
		if pRequest.Mode = "verify" {
			do ##class(DTL.Service.SpecConcise).Verify($this, tToken, pRequest.Provider, pRequest.Model, pRequest.ApiKey, pRequest.Region)
		} else {
			// Generate commits READY/ERROR itself. On success, run the (separate,
			// non-blocking) audit too — now inside this supervised, redeliverable worker.
			set tGenSC = ##class(DTL.Service.SpecConcise).Generate($this, tToken, pRequest.Provider, pRequest.Model, pRequest.ApiKey, pRequest.Region)
			if $$$ISOK(tGenSC) {
				set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(tToken, .sc)
				if $isobject(tDoc), tDoc.ConciseStatus = "READY" {
					set tDoc.ConciseVerifyStatus = "PENDING"  do tDoc.%Save()
					do ##class(DTL.Service.SpecConcise).Verify($this, tToken, pRequest.Provider, pRequest.Model, pRequest.ApiKey, pRequest.Region)
				}
			}
		}
	} catch ex {
		// Defence in depth: Generate/Verify already trap and record their own errors,
		// but if anything escapes, make sure the record never stays PENDING.
		set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(tToken, .sc)
		if $isobject(tDoc) {
			if pRequest.Mode = "verify" {
				set tDoc.ConciseVerifyStatus = "ERROR"
			} elseif tDoc.ConciseStatus '= "READY" {
				set tDoc.ConciseStatus = "ERROR", tDoc.ConciseError = ex.DisplayString()
			} else {
				set tDoc.ConciseVerifyStatus = "ERROR"
			}
			do tDoc.%Save()
		}
		// Returning OK (not the error %Status) so Ensemble does NOT redeliver: a caught
		// application error (bad key, truncated reply) is terminal and already recorded
		// on the SpecDoc — redelivering it would just burn the same call again. Only an
		// uncaught PROCESS DEATH (which never reaches this catch) triggers redelivery.
	}
	quit $$$OK
}

Storage Default
{
<Type>%Storage.Persistent</Type>
}

}
