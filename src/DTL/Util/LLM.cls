/// Stateless one-shot LLM caller for code paths that run OUTSIDE a hosted component
/// and only need a single reply without a Job record — e.g. the no-production inline
/// fallback for concise-spec generation, and tests. It submits through the inbound
/// business service DTL.Svc.ApiService to the shared DTL.Op.LLMConnector, reusing the
/// same provider wiring (OpenAI / Bedrock / mock), auth, timeouts and retry.
///
/// NOTE: a hosted component (a Business Process such as DTL.Proc.SpecForge) must NOT
/// call Chat — it should send to the LLM operation DIRECTLY with ..SendRequestSync so
/// the call is a child message of that host in the Visual Trace. Use BuildRequest to
/// assemble the message, then send it yourself. Chat is only for non-hosted callers.
Class DTL.Util.LLM Extends %RegisteredObject
{

Parameter LLMTARGET = "DTL.Op.LLMConnector";

/// One-shot chat: send a system + user prompt, return the raw assistant text ("" on
/// failure with pErr set). Tokens/cost come back byref so the caller can record them.
/// Build an LLMRequest carrying a system + user turn. Shared by Chat (testing-service
/// path) and by hosted Business Processes that issue ..SendRequestSync to the
/// LLMConnector directly (so the call shows as a child message in their Visual Trace).
ClassMethod BuildRequest(pProvider As %String, pModel As %String, pApiKey As %String, pSystem As %String, pUser As %String, pRegion As %String = "", pMaxTokens As %Integer = 0) As DTL.Msg.LLMRequest
{
	set tReq = ##class(DTL.Msg.LLMRequest).%New()
	set tReq.Provider = pProvider
	set tReq.Model = pModel
	set tReq.ApiKey = pApiKey
	set tReq.BedrockRegion = pRegion
	if pMaxTokens > 0 set tReq.MaxTokens = pMaxTokens
	if pSystem '= "" {
		set tS = ##class(DTL.Msg.ChatTurn).%New()
		set tS.Role = "system", tS.Content = pSystem
		do tReq.Transcript.Insert(tS)
	}
	set tU = ##class(DTL.Msg.ChatTurn).%New()
	set tU.Role = "user", tU.Content = pUser
	do tReq.Transcript.Insert(tU)
	quit tReq
}

/// Like BuildRequest, but with a large STATIC, CACHEABLE prefix as the first system
/// block (flagged CacheBreakpoint) followed by a small persona system block and the
/// per-call user message. The prefix is billed at full input price once and re-read
/// from cache on subsequent calls that share the identical prefix (Anthropic/Bedrock
/// cache_control via LLMConnector; OpenAI auto-caches a stable ≥1024-token prefix).
/// Used by the spec generate/audit path, where the (big) source document is identical
/// across both calls, the length-escalation retry, and any regeneration.
ClassMethod BuildRequestCached(pProvider As %String, pModel As %String, pApiKey As %String, pCachedPrefix As %String, pPersona As %String, pUser As %String, pRegion As %String = "", pMaxTokens As %Integer = 0) As DTL.Msg.LLMRequest
{
	set tReq = ##class(DTL.Msg.LLMRequest).%New()
	set tReq.Provider = pProvider, tReq.Model = pModel, tReq.ApiKey = pApiKey, tReq.BedrockRegion = pRegion
	if pMaxTokens > 0 set tReq.MaxTokens = pMaxTokens
	if pCachedPrefix '= "" {
		set tP = ##class(DTL.Msg.ChatTurn).%New()
		set tP.Role = "system", tP.Content = pCachedPrefix, tP.CacheBreakpoint = 1
		do tReq.Transcript.Insert(tP)
	}
	if pPersona '= "" {
		set tS = ##class(DTL.Msg.ChatTurn).%New()
		set tS.Role = "system", tS.Content = pPersona
		do tReq.Transcript.Insert(tS)
	}
	set tU = ##class(DTL.Msg.ChatTurn).%New()
	set tU.Role = "user", tU.Content = pUser
	do tReq.Transcript.Insert(tU)
	quit tReq
}

ClassMethod Chat(pProvider As %String, pModel As %String, pApiKey As %String, pSystem As %String, pUser As %String, Output pErr As %String, pRegion As %String = "", Output pInTok As %Integer, Output pOutTok As %Integer, Output pCost As %Numeric, pMaxTokens As %Integer = 0, Output pFinishReason As %String) As %String
{
	set tReq = ..BuildRequest(pProvider, pModel, pApiKey, pSystem, pUser, pRegion, pMaxTokens)
	quit ..ChatReq(tReq, .pErr, .pInTok, .pOutTok, .pCost, .pFinishReason)
}

/// Send a PRE-BUILT request in-process (no interop host) and return the raw reply,
/// with token usage/cost/finish reason byref. Shared by Chat and the cached-prefix
/// spec path so both go through one place.
ClassMethod ChatReq(pReq As DTL.Msg.LLMRequest, Output pErr As %String, Output pInTok As %Integer, Output pOutTok As %Integer, Output pCost As %Numeric, Output pFinishReason As %String) As %String
{
	set pErr = "", pInTok = 0, pOutTok = 0, pCost = 0, pFinishReason = ""
	set sc = ##class(Ens.Director).CreateBusinessService("DTL.Svc.ApiService", .tSvc)
	if $$$ISERR(sc) { set pErr = $system.Status.GetErrorText(sc) quit "" }
	set sc = tSvc.LLM(pReq, .tResp)
	if $$$ISERR(sc) { set pErr = $system.Status.GetErrorText(sc) quit "" }
	if '$isobject(tResp) { set pErr = "no response" quit "" }
	set pFinishReason = tResp.FinishReason
	set pInTok = +tResp.InputTokens, pOutTok = +tResp.OutputTokens
	set pCost = ##class(DTL.Util.Pricing).Cost(pReq.Model, pInTok, pOutTok)
	set tRaw = ##class(DTL.Data.Job).StreamStr(tResp.RawContent)
	if tRaw = "" { set pErr = $select(tResp.ErrorText'="":tResp.ErrorText, 1:"empty response") quit "" }
	quit tRaw
}

/// Parse a strict-JSON object out of an LLM reply that may be wrapped in prose or a
/// ```json fence. Returns the %DynamicObject or "" if none parses. (Shared by the
/// concise-spec + judge paths.)
ClassMethod ParseJSON(pReply As %String) As %DynamicObject
{
	set tTxt = pReply
	if tTxt [ "```" {
		set tOpen = $find(tTxt, "```")
		set tNL = $find(tTxt, $char(10), tOpen)
		if tNL = 0 set tNL = tOpen
		set tClose = $find(tTxt, "```", tNL)
		if tClose > 0 set tTxt = $extract(tTxt, tNL, tClose - 4)
	}
	set tS = $find(tTxt, "{") - 1
	set tE = 0
	for i = $length(tTxt):-1:1 { if $extract(tTxt, i) = "}" set tE = i quit }
	if (tS <= 0) || (tE = 0) || (tE < tS) quit ""
	try { return ##class(%DynamicAbstractObject).%FromJSON($extract(tTxt, tS, tE)) } catch { return "" }
}

}
