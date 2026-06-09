/// Business Operation that calls an OpenAI-compatible Chat Completions endpoint
/// over HTTP and returns the assistant's reply with the DTL class extracted.
///
/// The same wire format works against the real OpenAI API and against the local
/// mock (mock/mock_llm.py). Switch with the <property>Mode</property> setting:
///   mock   -> plaintext HTTP to the mock (default; no API key, no TLS needed)
///   openai -> HTTPS to api.openai.com (requires an SSLConfig + ApiKey credential)
///
/// HTTP transport is done through the hosted EnsLib.HTTP.OutboundAdapter so the
/// host/port/SSL are configured as production settings and every call is traced.
Class DTL.Op.LLMConnector Extends Ens.BusinessOperation
{

Parameter ADAPTER = "EnsLib.HTTP.OutboundAdapter";

Parameter INVOCATION = "Queue";

/// mock | openai. Controls defaults but the wire format is identical.
Property Mode As %String(VALUELIST = ",mock,openai") [ InitialExpression = "mock" ];

/// Chat completions path on the server.
Property ChatPath As %String [ InitialExpression = "/v1/chat/completions" ];

/// Default model id if the request does not specify one.
Property Model As %String [ InitialExpression = "gpt-4o" ];

/// Name of an Ens credentials entry holding the API key as its password.
/// Leave blank for the mock (which ignores auth).
Property ApiKeyCredentials As %String;

/// Hostnames/ports for the two providers. The adapter target is set at call time
/// from the per-request Provider so one operation serves both without reconfig.
Property OpenAIHost As %String [ InitialExpression = "api.openai.com" ];

Property OpenAIPort As %Integer [ InitialExpression = 443 ];

/// SSL config name used for the HTTPS OpenAI connection (created by the Installer).
Property OpenAISSLConfig As %String [ InitialExpression = "DTLOpenAISSL" ];

Property MockHost As %String [ InitialExpression = "localhost" ];

Property MockPort As %Integer [ InitialExpression = 8085 ];

Parameter SETTINGS = "Mode:Basic,ChatPath:Basic,Model:Basic,OpenAIHost:Basic,OpenAIPort:Basic,OpenAISSLConfig:Basic,MockHost:Basic,MockPort:Basic,ApiKeyCredentials:Basic:credentialsSelector";

/// Map the request type to the handler method.
XData MessageMap
{
<MapItems>
  <MapItem MessageType="DTL.Msg.LLMRequest">
    <Method>ChatCompletion</Method>
  </MapItem>
</MapItems>
}

/// Send the accumulated transcript to the LLM and return its reply.
Method ChatCompletion(pReq As DTL.Msg.LLMRequest, Output pResp As DTL.Msg.LLMResponse) As %Status
{
	set pResp = ##class(DTL.Msg.LLMResponse).%New()
	set pResp.JobId = pReq.JobId
	set pResp.Attempt = pReq.Attempt
	set tSC = $$$OK
	try {
		// --- Build the OpenAI chat-completions JSON body ---
		set tMessages = []
		for i = 1:1:pReq.Transcript.Count() {
			set tTurn = pReq.Transcript.GetAt(i)
			do tMessages.%Push({"role": (tTurn.Role), "content": (tTurn.Content)})
		}
		set tModel = $select(pReq.Model '= "":pReq.Model, 1:..Model)
		set tBody = {
			"model": (tModel),
			"temperature": (pReq.Temperature),
			"max_tokens": (pReq.MaxTokens),
			"messages": (tMessages)
		}

		set tJsonBody = tBody.%ToJSON()

		// --- Pick the provider (per-request override, else the Mode setting) and
		//     point the hosted adapter at it for this call. One operation serves
		//     both OpenAI (HTTPS + SSL) and the offline mock (plaintext). ---
		set tProvider = $select(pReq.Provider '= "":pReq.Provider, 1:..Mode)
		if tProvider = "openai" {
			set ..Adapter.HTTPServer = ..OpenAIHost
			set ..Adapter.HTTPPort = ..OpenAIPort
			set ..Adapter.SSLConfig = ..OpenAISSLConfig
		} else {
			set ..Adapter.HTTPServer = ..MockHost
			set ..Adapter.HTTPPort = ..MockPort
			set ..Adapter.SSLConfig = ""
		}

		// --- Build a request object to carry headers (ContentType + auth) ---
		set tHttpReq = ##class(%Net.HttpRequest).%New()
		set tHttpReq.ContentType = "application/json"

		// Authorization header. Prefer the per-request key the user supplied in the
		// UI; otherwise fall back to the operation's configured credentials. The
		// header is sent whenever a key is available (mock ignores it).
		set tKey = $select(pReq.ApiKey '= "":pReq.ApiKey, 1:..GetApiKey())
		if tKey '= "" do tHttpReq.SetHeader("Authorization", "Bearer " _ tKey)

		// Send via the hosted adapter. Per EnsLib.HTTP.OutboundAdapter: to send a
		// raw request BODY (not form variables), leave pFormVarNames empty and pass
		// the body as a SUBSCRIPTED pData node (pData(1)) -- the adapter iterates
		// pData via $ORDER and writes each node to EntityBody. pOp must be "Post".
		kill tData
		set tData(1) = tJsonBody
		set tSC = ..Adapter.SendFormDataArray(.tHttpResp, "Post", tHttpReq, "", .tData, ..ChatPath)
		if $$$ISERR(tSC) {
			// A non-2xx HTTP status (e.g. 400 for a bad model) surfaces here as an
			// <Ens>ErrHTTPStatus transport error AND, usually, a populated response
			// body. Prefer the provider's own error JSON (descriptive) over the raw
			// transport status text.
			set tStatusTxt = $system.Status.GetErrorText(tSC)
			set tCode = $select($isobject($get(tHttpResp)):+tHttpResp.StatusCode, 1:0)
			set tBody = ""
			try { if $isobject($get(tHttpResp)), $isobject(tHttpResp.Data) { set tBody = tHttpResp.Data.Read(3600000) } } catch {}
			set pResp.HttpStatus = tCode
			if (tCode '= 0) {
				set pResp.ErrorText = ..DescribeHttpError(tCode, tBody, tProvider, tModel)
			} else {
				set pResp.ErrorText = ..DescribeTransport(tStatusTxt, tProvider)
			}
			set pResp.Ok = 0
			quit  // return OK status; the BP inspects pResp.Ok
		}

		set pResp.HttpStatus = $select($isobject($get(tHttpResp)):tHttpResp.StatusCode, 1:0)
		if '$isobject($get(tHttpResp)) {
			set pResp.ErrorText = "No HTTP response object returned"
			set pResp.Ok = 0
			quit
		}

		set tRespBody = tHttpResp.Data.Read(3600000)
		if (pResp.HttpStatus < 200) || (pResp.HttpStatus >= 300) {
			set pResp.ErrorText = ..DescribeHttpError(pResp.HttpStatus, tRespBody, tProvider, tModel)
			set pResp.Ok = 0
			quit
		}

		// --- Parse the JSON response defensively ---
		set tJson = {}.%FromJSON(tRespBody)
		set tContent = ""
		try {
			set tContent = tJson.choices.%Get(0).message.content
			set pResp.FinishReason = tJson.choices.%Get(0)."finish_reason"
		} catch {
			set tContent = ""
		}
		if $isobject(tJson.usage) set pResp.TotalTokens = +tJson.usage."total_tokens"
		do pResp.RawContent.Write(tContent)

		if tContent = "" {
			set pResp.ErrorText = "Empty/unparseable completion content"
			set pResp.Ok = 0
			quit
		}

		// --- Extract the DTL class from the reply ---
		set tClassSrc = ##class(DTL.Util.Extractor).Extract(tContent, .tClassName, .tValid)
		do pResp.ExtractedClass.Write(tClassSrc)
		set pResp.ClassName = tClassName
		set pResp.Ok = tValid
		if 'tValid set pResp.ErrorText = "Reply did not contain a valid DTL class definition"
	} catch ex {
		set pResp.Ok = 0
		set pResp.ErrorText = "Exception: " _ ex.DisplayString()
	}
	// Always return OK; the BP decides what to do based on pResp.Ok.
	quit $$$OK
}

/// Turn a non-2xx HTTP response into a human-actionable message. OpenAI returns
/// {"error":{"message","type","code","param"}} — surface that verbatim and add a
/// plain-English hint for the common cases (bad model, auth, rate limit, quota).
ClassMethod DescribeHttpError(pCode As %Integer, pBody As %String, pProvider As %String, pModel As %String) As %String
{
	set tMsg = "", tType = "", tCode = ""
	try {
		set tJson = {}.%FromJSON(pBody)
		if $isobject(tJson.error) {
			set tMsg = tJson.error.message
			set tType = tJson.error.type
			set tCode = tJson.error."code"
		} elseif (tJson.message '= "") {
			set tMsg = tJson.message
		}
	} catch {
		set tMsg = ""
	}
	if tMsg = "" set tMsg = $extract($zstrip(pBody, "<>W"), 1, 600)

	// Plain-English hint, keyed by HTTP status FIRST (authoritative), then the
	// model-specific case. (OpenAI tags a bad-model 400 with type
	// 'invalid_request_error', so we must branch on the status code, not the type.)
	set tHint = ""
	set tModelProblem = (tCode = "model_not_found") || ((tMsg [ "model") && ((tMsg [ "does not exist") || (tMsg [ "do not have access")))
	if (pCode = 401) {
		set tHint = "Authentication failed (HTTP 401). Check that your API key is correct and not expired."
	} elseif (pCode = 403) {
		set tHint = "Access denied (HTTP 403). Your key may not have access to this model or endpoint."
	} elseif (pCode = 404) {
		set tHint = "Not found (HTTP 404) — often a wrong model id or chat path."
	} elseif (pCode = 429) {
		set tHint = "Rate limited or out of quota (HTTP 429). Wait and retry, or check your plan's billing/limits."
	} elseif (pCode >= 500) {
		set tHint = "The provider had a server error (HTTP " _ pCode _ "). This is usually transient — retry shortly."
	} elseif tModelProblem {
		set tHint = "The selected model """ _ pModel _ """ is not valid for your account / endpoint. Pick a different model (use the ⟳ button to load the models your key can access)."
	} elseif (pCode = 400) || (tType [ "invalid_request") {
		set tHint = "The request was rejected as invalid (HTTP 400). Check the selected model and your inputs."
	}

	set tOut = "LLM request failed (HTTP " _ pCode _ ")"
	if tType '= "" set tOut = tOut _ " [" _ tType _ $select(tCode'="":"/" _ tCode, 1:"") _ "]"
	set tOut = tOut _ ": " _ tMsg
	if tHint '= "" set tOut = tOut _ "  → " _ tHint
	quit $extract(tOut, 1, 1900)
}

/// Describe a transport-level failure (no HTTP status — DNS, TLS, refused, etc.).
ClassMethod DescribeTransport(pStatusTxt As %String, pProvider As %String) As %String
{
	set tHint = ""
	if (pStatusTxt [ "SSL") || (pStatusTxt [ "TLS") {
		set tHint = "TLS/SSL problem reaching the provider — check the SSL configuration (DTLOpenAISSL)."
	} elseif (pStatusTxt [ "refused") || (pStatusTxt [ "connect") {
		set tHint = $select(pProvider="mock":"The mock LLM server isn't reachable on its host/port (is mock_llm.py running on 8085?).", 1:"Could not connect to the provider host — check network policy/firewall and the host/port settings.")
	} elseif (pStatusTxt [ "timed out") || (pStatusTxt [ "Timeout") {
		set tHint = "The request timed out before the provider responded."
	}
	set tOut = "Could not reach the LLM provider: " _ pStatusTxt
	if tHint '= "" set tOut = tOut _ "  → " _ tHint
	quit $extract(tOut, 1, 1900)
}

/// Resolve the API key from the configured Ens credentials entry.
Method GetApiKey() As %String
{
	quit:..ApiKeyCredentials="" ""
	set tCred = ##class(Ens.Config.Credentials).%OpenId(..ApiKeyCredentials)
	quit:'$isobject(tCred) ""
	quit tCred.Password
}

}
