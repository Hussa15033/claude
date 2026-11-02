/// The framework's single INBOUND boundary into the interoperability production.
///
/// Everything that originates OUTSIDE a running host — the REST layer, the
/// installer, tests — submits its work by creating THIS business service and
/// calling one of its methods, which then sends the message on to the right host
/// (operation or process) with SendRequestSync / SendRequestAsync. That is exactly
/// what a Business Service is for: it is the supported way to get a message INTO a
/// production. (We deliberately do NOT use EnsLib.Testing.Service for this — that is
/// a test harness, not an application entry point, and using it hides the real call
/// graph in the Visual Trace.)
///
/// Component-to-component traffic does NOT go through here: once a message is inside
/// a host, that host sends onward directly (e.g. DTL.Proc.SpecForge issues its own
/// ..SendRequestSync to DTL.Op.LLMConnector). This service is only the doorway in.
///
/// Adapterless: it is driven programmatically (Ens.Director.CreateBusinessService),
/// not by an inbound adapter polling a feed, so it has no ADAPTER parameter.
Class DTL.Svc.ApiService Extends Ens.BusinessService
{

/// Config name of the LLM business operation.
Parameter LLMTARGET = "DTL.Op.LLMConnector";

/// Config name of the concise-spec business process.
Parameter SPECFORGE = "DTL.Proc.SpecForge";

/// Config name of the (legacy auto-run) forge orchestrator business process.
Parameter ORCHESTRATOR = "DTL.Proc.Orchestrator";

/// Generous timeout (seconds) for a synchronous LLM call — reasoning / large-output
/// models can take minutes; aligned with the operation's FailureTimeout.
Parameter LLMTIMEOUT = 600;

/// Adapterless service: no inbound feed. OnProcessInput is required by the class but
/// unused — callers invoke the typed helpers below instead.
Method OnProcessInput(pInput As %RegisteredObject, Output pOutput As %RegisteredObject) As %Status
{
	quit $$$OK
}

/// Send a prepared LLM request SYNCHRONOUSLY to the LLM operation and return its
/// response. Used by callers that need the reply in-line (the gated StepEngine, the
/// one-shot DTL.Util.LLM). Fully traced: ApiService -> LLMConnector -> ApiService.
Method LLM(pReq As DTL.Msg.LLMRequest, Output pResp As DTL.Msg.LLMResponse) As %Status
{
	quit ..SendRequestSync(..#LLMTARGET, pReq, .pResp, ..#LLMTIMEOUT)
}

/// Submit a concise-spec request ASYNCHRONOUSLY onto the SpecForge process queue.
/// Durable: the request is persisted, a pooled worker always processes it, and a
/// worker death triggers Ensemble redelivery — so it can never strand at PENDING.
Method SubmitConcise(pReq As DTL.Msg.ConciseRequest) As %Status
{
	quit ..SendRequestAsync(..#SPECFORGE, pReq)
}

/// Submit a forge request ASYNCHRONOUSLY onto the orchestrator (legacy auto-run path).
Method SubmitForge(pReq As DTL.Msg.ForgeRequest) As %Status
{
	quit ..SendRequestAsync(..#ORCHESTRATOR, pReq)
}

}
