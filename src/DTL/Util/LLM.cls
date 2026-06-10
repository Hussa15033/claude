/// Stateless one-shot LLM caller for steps that are NOT part of a job's build
/// conversation — e.g. generating/verifying the concise spec at upload time. Builds
/// a transient, fully-traced request through EnsLib.Testing.Service to the shared
/// DTL.Op.LLMConnector, so it reuses the same provider wiring (OpenAI / Bedrock /
/// mock), auth, timeouts and retry as the main loop without needing a Job record.
Class DTL.Util.LLM Extends %RegisteredObject
{

Parameter LLMTARGET = "DTL.Op.LLMConnector";

/// One-shot chat: send a system + user prompt, return the raw assistant text ("" on
/// failure with pErr set). Tokens/cost come back byref so the caller can record them.
ClassMethod Chat(pProvider As %String, pModel As %String, pApiKey As %String, pSystem As %String, pUser As %String, Output pErr As %String, pRegion As %String = "", Output pInTok As %Integer, Output pOutTok As %Integer, Output pCost As %Numeric, pMaxTokens As %Integer = 0, Output pFinishReason As %String) As %String
{
	set pErr = "", pInTok = 0, pOutTok = 0, pCost = 0, pFinishReason = ""
	set sc = ##class(Ens.Director).CreateBusinessService("EnsLib.Testing.Service", .tSvc)
	if $$$ISERR(sc) { set pErr = $system.Status.GetErrorText(sc) quit "" }
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
	set sc = tSvc.SendRequestSync(..#LLMTARGET, tReq, .tResp, 600)
	if $$$ISERR(sc) { set pErr = $system.Status.GetErrorText(sc) quit "" }
	if '$isobject(tResp) { set pErr = "no response" quit "" }
	set pFinishReason = tResp.FinishReason
	set pInTok = +tResp.InputTokens, pOutTok = +tResp.OutputTokens
	set pCost = ##class(DTL.Util.Pricing).Cost(pModel, pInTok, pOutTok)
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
