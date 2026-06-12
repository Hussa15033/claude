/// REST API for the DTL GenAI framework, served at the /dtl/api web application.
///
/// Routes:
///   GET  /health            - init/health check (the test hook), 200 if all green
///   GET  /schemas           - list installed HL7 schema categories (versions)
///   POST /generate          - start a generation job; returns {jobId}
///   GET  /jobs/{id}          - full job status incl. live attempts + diff messages
///   GET  /jobs/{id}/dtl      - the final generated DTL class source (text/plain)
///   GET  /jobs               - list recent jobs (id/status/score)
///
/// All JSON; permissive CORS so a separately-hosted UI can call it too (the
/// bundled UI is same-origin under /dtl/ui).
Class DTL.REST.Dispatch Extends %CSP.REST
{

Parameter CONTENTTYPE = "application/json";

Parameter CHARSET = "utf-8";

/// Allow cross-origin calls (handy during UI development).
Parameter HandleCorsRequest = 1;

XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
  <Route Url="/health"          Method="GET"  Call="Health"   Cors="true"/>
  <Route Url="/schemas"         Method="GET"  Call="Schemas"  Cors="true"/>
  <Route Url="/models"          Method="POST" Call="Models"   Cors="true"/>
  <Route Url="/bedrock-models"  Method="POST" Call="BedrockModels" Cors="true"/>
  <Route Url="/upload"          Method="POST" Call="Upload"   Cors="true"/>
  <Route Url="/specs"           Method="GET"  Call="ListSpecs" Cors="true"/>
  <Route Url="/specs/:token"    Method="GET"  Call="GetSpec"  Cors="true"/>
  <Route Url="/specs/:token/original" Method="GET" Call="OrigDoc" Cors="true"/>
  <Route Url="/specs/:token/concise"         Method="POST" Call="ConciseSpec"        Cors="true"/>
  <Route Url="/specs/:token/approve-concise" Method="POST" Call="ApproveConcise"     Cors="true"/>
  <Route Url="/generate"        Method="POST" Call="Generate" Cors="true"/>
  <Route Url="/jobs"            Method="GET"  Call="ListJobs" Cors="true"/>
  <Route Url="/jobs/:id"        Method="GET"  Call="GetJob"   Cors="true"/>
  <Route Url="/jobs/:id/dtl"    Method="GET"  Call="GetDTL"   Cors="true"/>
  <Route Url="/jobs/:id/continue" Method="POST" Call="ContinueJob" Cors="true"/>
  <Route Url="/jobs/:id/refine" Method="POST" Call="RefineJob" Cors="true"/>
  <Route Url="/jobs/:id/messages" Method="GET" Call="JobMessages" Cors="true"/>
  <Route Url="/jobs/:id/outputs" Method="GET" Call="JobOutputs" Cors="true"/>
  <Route Url="/jobs/:id/transform" Method="POST" Call="JobTransform" Cors="true"/>
  <Route Url="/jobs/:id/correct" Method="POST" Call="CorrectJob" Cors="true"/>
  <Route Url="/classes"         Method="GET"  Call="Classes"  Cors="true"/>
  <Route Url="/history"         Method="GET"  Call="History"  Cors="true"/>
  <Route Url="/links"           Method="GET"  Call="Links"    Cors="true"/>
  <Route Url="/links/:id"       Method="GET"  Call="Links"    Cors="true"/>
</Routes>
}

/// GET /health - run the init/health test hook and return its structured result.
ClassMethod Health() As %Status
{
	set tRes = ##class(DTL.Test.HealthCheck).RunJSON()
	set %response.Status = $select(tRes.ok:"200 OK", 1:"503 Service Unavailable")
	do ..Json(tRes)
	quit $$$OK
}

/// GET /schemas - installed HL7 schema categories (e.g. 2.3, 2.5, 2.5.1).
ClassMethod Schemas() As %Status
{
	set tArr = []
	set k = ""
	for {
		set k = $order(^EnsHL7.Schema(k))
		quit:k=""
		do tArr.%Push(k)
	}
	do ..Json({"schemas": (tArr)})
	quit $$$OK
}

/// POST /models - body {apiKey}. Server-side proxy to OpenAI GET /v1/models so
/// the browser never has to call OpenAI directly (no CORS, key stays same-origin).
/// Returns {models:[ids...]} filtered to chat-capable models, newest-ish first.
ClassMethod Models() As %Status
{
	set tPayload = ..ReadBody(.tSC)
	set tKey = $select($$$ISOK(tSC):tPayload.apiKey, 1:"")
	if tKey = "" quit ..ErrJson(400, "An OpenAI API key is required to list models.")
	try {
		set http = ##class(%Net.HttpRequest).%New()
		set http.Server = "api.openai.com", http.Port = 443, http.Https = 1, http.Timeout = 20
		set http.SSLConfiguration = "DTLOpenAISSL"
		do http.SetHeader("Authorization", "Bearer " _ tKey)
		set sc = http.Get("/v1/models")
		if $$$ISERR(sc) return ..ErrJson(502, "Could not reach OpenAI: " _ $system.Status.GetErrorText(sc))
		set tBody = http.HttpResponse.Data.Read(3600000)
		if (http.HttpResponse.StatusCode '= 200) {
			return ..ErrJson(http.HttpResponse.StatusCode, "OpenAI /v1/models returned HTTP " _ http.HttpResponse.StatusCode _ ": " _ $extract(tBody, 1, 500))
		}
		set tJson = {}.%FromJSON(tBody)
		set tIds = []
		set it = tJson.data.%GetIterator()
		while it.%GetNext(.k, .m) {
			set id = m.id
			// keep chat/reasoning families, drop embeddings/audio/image/tts/whisper/etc.
			continue:'..IsChatModel(id)
			do tIds.%Push(id)
		}
		do ..Json({"models": (tIds)})
	} catch ex {
		return ..ErrJson(500, "models error: " _ ex.DisplayString())
	}
	quit $$$OK
}

/// Heuristic: is this OpenAI model id usable for chat completions?
ClassMethod IsChatModel(pId As %String) As %Boolean
{
	set l = $zconvert(pId, "L")
	// exclude obvious non-chat families
	if (l["embedding")||(l["whisper")||(l["tts")||(l["audio")||(l["dall-e")||(l["image")||(l["moderation")||(l["realtime")||(l["transcribe")||(l["search")||(l["babbage")||(l["davinci")||(l["instruct") quit 0
	// include the chat/reasoning families
	quit (l["gpt-4")||(l["gpt-3.5")||(l["chatgpt")||($extract(l)="o")
}

/// POST /bedrock-models - body {apiKey, region}. Server-side proxy to the Bedrock
/// control plane to list the account's Anthropic INFERENCE PROFILES (the ids you
/// can actually invoke on-demand — a bare foundation-model id like
/// anthropic.claude-opus-4-7 returns "on-demand throughput isn't supported").
/// Returns {models:[ids...]} (inference-profile ids first, then on-demand
/// foundation models). Falls back to a built-in list if the listing call fails.
ClassMethod BedrockModels() As %Status
{
	set tPayload = ..ReadBody(.tSC)
	set tKey = $select($$$ISOK(tSC):tPayload.apiKey, 1:"")
	set tRegion = $select($$$ISOK(tSC)&&(tPayload.region'=""):tPayload.region, 1:"us-east-1")
	if tKey = "" quit ..ErrJson(400, "An AWS Bedrock API key is required to list models.")
	set tIds = []
	set tSeen = ""
	try {
		// 1) Inference profiles — these are the directly-invokable ids (us.anthropic.*).
		set tProf = ..BedrockGet(tRegion, tKey, "/inference-profiles?maxResults=1000", .tpsc)
		if $isobject(tProf), $isobject(tProf."inferenceProfileSummaries") {
			set it = tProf."inferenceProfileSummaries".%GetIterator()
			while it.%GetNext(.k, .m) {
				set id = m."inferenceProfileId"
				continue:'($zconvert(id,"L")["anthropic")
				continue:tSeen[(""""_id_"""")
				do tIds.%Push(id) set tSeen=tSeen_""""_id_""""
			}
		}
		// 2) On-demand foundation models (some accounts can invoke these directly).
		set tFm = ..BedrockGet(tRegion, tKey, "/foundation-models?byProvider=anthropic&byInferenceType=ON_DEMAND", .tfsc)
		if $isobject(tFm), $isobject(tFm."modelSummaries") {
			set it2 = tFm."modelSummaries".%GetIterator()
			while it2.%GetNext(.k, .m) {
				set id = m."modelId"
				continue:tSeen[(""""_id_"""")
				do tIds.%Push(id) set tSeen=tSeen_""""_id_""""
			}
		}
	} catch ex {
	}
	// Fallback to a sane built-in list if the listing produced nothing. The global
	// cross-region inference profile is the preferred default (highest availability).
	if tIds.%Size() = 0 {
		for id = "global.anthropic.claude-opus-4-8","us.anthropic.claude-opus-4-8-v1:0","us.anthropic.claude-opus-4-7-v1:0","us.anthropic.claude-sonnet-4-6-v1:0","us.anthropic.claude-haiku-4-5-v1:0" { do tIds.%Push(id) }
		do ..Json({"models": (tIds), "note": "Could not list from Bedrock (check key/region/permissions) — showing common inference-profile ids."})
		quit $$$OK
	}
	do ..Json({"models": (tIds)})
	quit $$$OK
}

/// GET against the Bedrock CONTROL plane (bedrock.<region>.amazonaws.com) using the
/// bearer API key. Returns the parsed JSON object, or "" on non-200. The control
/// plane (model/profile listing) is a different host from bedrock-runtime (invoke).
ClassMethod BedrockGet(pRegion As %String, pKey As %String, pPath As %String, Output pSC As %Status) As %DynamicObject
{
	set pSC = $$$OK
	set http = ##class(%Net.HttpRequest).%New()
	set http.Server = "bedrock." _ pRegion _ ".amazonaws.com", http.Port = 443, http.Https = 1, http.Timeout = 20
	set http.SSLConfiguration = "DTLOpenAISSL"
	do http.SetHeader("Authorization", "Bearer " _ pKey)
	set sc = http.Get(pPath)
	if $$$ISERR(sc) { set pSC = sc  quit "" }
	if (http.HttpResponse.StatusCode '= 200) { set pSC = $$$ERROR($$$GeneralError, "HTTP " _ http.HttpResponse.StatusCode)  quit "" }
	set tBody = http.HttpResponse.Data.Read(3600000)
	quit {}.%FromJSON(tBody)
}

/// GET /links  or  /links/:id - deep links into the IRIS Management Portal:
/// the production config page, and (when :id given) the Visual Trace for that
/// job's interop session. Returns absolute, same-host URLs the UI can render.
ClassMethod Links(pId As %String = "") As %Status
{
	set tBase = ..PortalBase()
	set o = {}
	set o.production = tBase _ "EnsPortal.ProductionConfig.zen?PRODUCTION=DTL.Setup.Production"
	set o.messages = tBase _ "EnsPortal.MessageViewer.zen"
	if pId '= "" {
		set tJob = ##class(DTL.Data.Job).OpenByJobId(pId, .sc)
		if $isobject(tJob), tJob.SessionId '= "" {
			set o.sessionId = tJob.SessionId
			set o.visualTrace = tBase _ "EnsPortal.VisualTrace.zen?SESSIONID=" _ tJob.SessionId
		}
	}
	do ..Json(o)
	quit $$$OK
}

/// Base URL for EnsPortal pages in this namespace, derived from the request host
/// so links work regardless of host/port. e.g. http://host:52773/csp/user/
/// Defensive: %request CGI vars are read inside a try so a missing var can never
/// 500 the endpoint; falls back to localhost:52773.
ClassMethod PortalBase() As %String
{
	set tHost = "", tPort = "", tScheme = "http"
	try {
		if $isobject($get(%request)) {
			set tHost = %request.GetCgiEnv("SERVER_NAME", "")
			set tPort = %request.GetCgiEnv("SERVER_PORT", "")
			set tHttps = %request.GetCgiEnv("HTTPS", "")
			if (tHttps = "on") || (tHttps = "ON") set tScheme = "https"
		}
	} catch {
	}
	if tHost = "" set tHost = "localhost"
	if tPort = "" set tPort = "52773"
	set tNs = $zconvert($namespace, "L")
	quit tScheme _ "://" _ tHost _ ":" _ tPort _ "/csp/" _ tNs _ "/"
}

/// POST /generate - body: {inputSpec, inputName, maxAttempts, successPolicy,
/// matchThreshold, pairs:[{input,output},...]}. Returns {jobId, status}.
ClassMethod Generate() As %Status
{
	set tPayload = ..ReadBody(.tSC)
	if $$$ISERR(tSC) quit ..ErrJson(400, "Invalid JSON body: " _ $system.Status.GetErrorText(tSC))

	set tSC = ##class(DTL.Service.JobManager).StartJob(tPayload, .tJobId, .tStartSC)
	if $$$ISERR(tSC) || $$$ISERR(tStartSC) {
		set tErr = $select($$$ISERR(tSC):tSC, 1:tStartSC)
		quit ..ErrJson(400, $system.Status.GetErrorText(tErr))
	}
	set %response.Status = "202 Accepted"
	do ..Json({"jobId": (tJobId), "status": "QUEUED"})
	quit $$$OK
}

/// GET /jobs/:id - full job document including live attempts + diff messages.
ClassMethod GetJob(pId As %String) As %Status
{
	set tJob = ##class(DTL.Data.Job).OpenByJobId(pId, .sc)
	if '$isobject(tJob) quit ..ErrJson(404, "No job with id '" _ pId _ "'")
	do ..Json(tJob.ToDynamic(1))
	quit $$$OK
}

/// GET /jobs/:id/dtl - the final generated DTL class source as text/plain.
ClassMethod GetDTL(pId As %String) As %Status
{
	set tJob = ##class(DTL.Data.Job).OpenByJobId(pId, .sc)
	if '$isobject(tJob) quit ..ErrJson(404, "No job with id '" _ pId _ "'")
	set %response.ContentType = "text/plain"
	do tJob.FinalDTL.Rewind()
	while 'tJob.FinalDTL.AtEnd { write tJob.FinalDTL.Read(16000) }
	quit $$$OK
}

/// POST /upload - body {filename, dataBase64}. Decodes the upload, writes it to
/// the watched specs/ directory as "<token>.<ext>", and returns {token}. The
/// DTL.Svc.SpecFileService (FileInboundAdapter) then extracts the text; the UI
/// polls GET /specs/{token}.
ClassMethod Upload() As %Status
{
	set tPayload = ..ReadBody(.tSC)
	if $$$ISERR(tSC) quit ..ErrJson(400, "Invalid JSON body")
	set tName = tPayload.filename
	set tB64 = tPayload.dataBase64
	if tB64 = "" quit ..ErrJson(400, "dataBase64 is required")
	try {
		set tSpecsDir = $get(^DTL.Config("specsDir"))
		if tSpecsDir = "" return ..ErrJson(503, "Spec directory not configured (run the installer).")
		set tToken = ##class(DTL.Service.JobManager).RandHex()
		set tExt = $zconvert($piece(tName, ".", *), "L")
		if (tExt = "") || (tExt = tName) set tExt = "txt"
		if $zstrip(tName, "<>W") = "" set tName = "spec." _ tExt   // never store a blank name
		// Record the ORIGINAL filename in a side global keyed by token. This is the
		// AUTHORITATIVE source of the display name: the file the watcher service sees
		// on disk is named "<token>.<ext>", so without this the service can only fall
		// back to that token name. Writing it here (before the file is created) makes
		// the original name available to the service regardless of record-commit
		// timing or whether the pre-created SpecDoc is visible cross-process yet.
		set ^DTL.SpecName(tToken) = tName
		// Pre-create the SpecDoc as PENDING so the UI can poll immediately.
		set tDoc = ##class(DTL.Data.SpecDoc).%New()
		set tDoc.Token = tToken, tDoc.FileName = tName, tDoc.Status = "PENDING"
		set tDoc.CreatedAt = ##class(DTL.Data.Job).Now()
		// Decode base64 -> binary. Persist the ORIGINAL bytes on the record (so the UI
		// can display the source PDF/image), then ALSO write them to the watched dir for
		// the file-watcher service to extract. The watcher later re-opens this record by
		// token and only sets Text/Status/etc., so OrigBytes survives.
		set tBin = $system.Encryption.Base64Decode(tB64)
		do tDoc.OrigBytes.Write(tBin)
		set tDoc.OrigExt = tExt
		set tDoc.OrigMime = ..MimeForExt(tExt)
		do tDoc.%Save()
		// Write the decoded bytes to a file in the watched dir.
		set tFile = ##class(%Stream.FileBinary).%New()
		set tFile.Filename = tSpecsDir _ tToken _ "." _ tExt
		do tFile.Write(tBin)
		set sc = tFile.%Save()
		if $$$ISERR(sc) return ..ErrJson(500, "Could not write upload: " _ $system.Status.GetErrorText(sc))
		set %response.Status = "202 Accepted"
		do ..Json({"token": (tToken), "status": "PENDING"})
	} catch ex {
		return ..ErrJson(500, "upload error: " _ ex.DisplayString())
	}
	quit $$$OK
}

/// GET /specs - list all previously uploaded specifications (newest first) so the
/// UI can offer a saved-spec picker (no re-upload / re-processing). Returns
/// {specs:[{token, fileName, status, size, createdAt}]} — text is fetched on
/// demand via GET /specs/:token.
ClassMethod ListSpecs() As %Status
{
	set tArr = []
	// Only list specs whose CONCISE specification has been reviewed and APPROVED —
	// an un-reviewed spec must not be reusable from the picker (it would bypass the
	// review gate). Newly-uploaded specs appear here only after the user approves.
	set tStmt = ##class(%SQL.Statement).%New()
	set sc = tStmt.%Prepare("SELECT Token,FileName,Status,CreatedAt FROM DTL_Data.SpecDoc WHERE ConciseApproved=1 ORDER BY ID DESC")
	if $$$ISOK(sc) {
		set rs = tStmt.%Execute()
		while rs.%Next() {
			set o = {}
			set o.token = rs.%Get("Token"), o.fileName = rs.%Get("FileName")
			set o.status = rs.%Get("Status"), o.createdAt = rs.%Get("CreatedAt")
			// size of the extracted markdown (chars) + extraction confidence, for display
			set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(o.token, .dsc)
			set o.size = $select($isobject(tDoc):tDoc.Text.Size, 1:0)
			set o.confidence = $select($isobject(tDoc):tDoc.Confidence, 1:"")
			set o.conciseApproved = $select($isobject(tDoc):tDoc.ConciseApproved, 1:0)
			do tArr.%Push(o)
		}
	}
	do ..Json({"specs": (tArr)})
	quit $$$OK
}

/// GET /specs/:token - the extraction status + text + concise spec for an upload.
ClassMethod GetSpec(pToken As %String) As %Status
{
	set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pToken, .sc)
	if '$isobject(tDoc) quit ..ErrJson(404, "No spec '" _ pToken _ "'")
	set tMetaObj = ""
	if tDoc.ExtractMeta '= "" { try { set tMetaObj = ##class(%DynamicAbstractObject).%FromJSON(tDoc.ExtractMeta) } catch {} }
	set tProvObj = "" set tProv = tDoc.ConciseProvStr()
	if tProv '= "" { try { set tProvObj = ##class(%DynamicAbstractObject).%FromJSON(tProv) } catch {} }
	set tVerObj = ""
	if tDoc.ConciseVerdict '= "" { try { set tVerObj = ##class(%DynamicAbstractObject).%FromJSON(tDoc.ConciseVerdict) } catch {} }
	do ..Json({"token": (tDoc.Token), "fileName": (tDoc.FileName), "status": (tDoc.Status), "text": (tDoc.TextStr()), "error": (tDoc.Error), "confidence": (tDoc.Confidence), "meta": (tMetaObj), "conciseStatus": (tDoc.ConciseStatus), "conciseApproved": (tDoc.ConciseApproved), "conciseSpec": (tDoc.ConciseStr()), "conciseProvenance": (tProvObj), "conciseVerdict": (tVerObj), "conciseError": (tDoc.ConciseError)})
	quit $$$OK
}

/// GET /specs/:token/original - stream back the originally-uploaded document bytes
/// with the right content-type, so the UI can show the source PDF/image inline.
/// 404 if the spec is unknown, or if it was uploaded before original bytes were stored.
ClassMethod OrigDoc(pToken As %String) As %Status
{
	set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pToken, .sc)
	if '$isobject(tDoc) quit ..ErrJson(404, "No spec '" _ pToken _ "'")
	if tDoc.OrigBytes.Size = 0 quit ..ErrJson(404, "Original document not stored for this spec.")
	// Serve the original document as base64 inside JSON. A raw binary body over this
	// %CSP.REST app (CHARSET=utf-8) gets run through a device translate table that
	// corrupts PDF/image bytes and blanks the viewer; base64 is plain ASCII, so it
	// survives intact and the browser decodes it to a Blob client-side.
	set %response.ContentType = "application/json"
	set tB64 = ""
	do tDoc.OrigBytes.Rewind()
	while 'tDoc.OrigBytes.AtEnd { set tB64 = tB64 _ $system.Encryption.Base64Encode(tDoc.OrigBytes.Read(12288), 1) }
	write {"mime": (tDoc.OrigMime), "ext": (tDoc.OrigExt), "fileName": (tDoc.FileName), "size": (tDoc.OrigBytes.Size), "dataBase64": (tB64)}.%ToJSON()
	quit $$$OK
}

/// POST /specs/:token/concise - body {provider, model, apiKey, region}. Kicks off
/// generation (and LLM-verify) of the concise, grouped, referenced specification in
/// the BACKGROUND and returns 202 immediately. Generation can require several large,
/// slow LLM calls; running it synchronously timed out the web gateway (504) on big
/// specs. The UI polls GET /specs/:token until conciseStatus is READY or ERROR.
ClassMethod ConciseSpec(pToken As %String) As %Status
{
	set tPayload = ..ReadBody(.tSC)
	if $$$ISERR(tSC) quit ..ErrJson(400, "Invalid JSON body")
	set tProvider = tPayload.provider, tModel = tPayload.model, tKey = tPayload.apiKey, tRegion = tPayload.region
	// Optional dedicated summarisation model for the concise/verify calls (cheaper +
	// faster than the build model). Falls back to the build model when not supplied.
	set tConciseModel = tPayload.conciseModel
	if $zstrip(tConciseModel, "<>W") = "" set tConciseModel = tModel
	// Fail fast with a clear message when config is missing (a live provider needs a
	// key + model). Saves a wasted round-trip and tells the user exactly what to fix.
	if (tProvider = "openai") || (tProvider = "bedrock") {
		if $zstrip(tKey, "<>W") = "" quit ..ErrJson(400, "No API key configured. Open Settings and enter your " _ $select(tProvider="bedrock":"AWS Bedrock", 1:"OpenAI") _ " API key (or switch Provider to Mock).")
		if $zstrip(tConciseModel, "<>W") = "" quit ..ErrJson(400, "No model selected. Open Settings, enter your API key, then choose a model.")
	}
	set sc = ##class(DTL.Service.SpecConcise).Start(pToken, tProvider, tConciseModel, tKey, tRegion)
	if $$$ISERR(sc) quit ..ErrJson(400, $system.Status.GetErrorText(sc))
	set %response.Status = "202 Accepted"
	do ..Json({"token": (pToken), "conciseStatus": "PENDING"})
	quit $$$OK
}

/// POST /specs/:token/approve-concise - body {conciseSpec}. Store the human-edited
/// concise spec and mark it APPROVED, so it drives generation without re-review.
ClassMethod ApproveConcise(pToken As %String) As %Status
{
	set tPayload = ..ReadBody(.tSC)
	if $$$ISERR(tSC) quit ..ErrJson(400, "Invalid JSON body")
	set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(pToken, .sc)
	if '$isobject(tDoc) quit ..ErrJson(404, "No spec '" _ pToken _ "'")
	set tConcise = tPayload.conciseSpec
	if $zstrip(tConcise, "<>W") '= "" {
		do tDoc.ConciseSpec.Clear()  do tDoc.ConciseSpec.Write(tConcise)
	}
	set tDoc.ConciseApproved = 1, tDoc.ConciseStatus = "READY"
	set sc = tDoc.%Save()
	if $$$ISERR(sc) quit ..ErrJson(500, $system.Status.GetErrorText(sc))
	quit ..GetSpec(pToken)
}

/// POST /jobs/:id/continue - body {action: approve|accept|reject, feedback,
/// planAdditions:[...]}. Advances a gated job one step (plan-approve / accept /
/// reject+regen). On "approve", planAdditions[] are extra plan items the USER
/// added; they are folded into the plan the model must implement.
ClassMethod ContinueJob(pId As %String) As %Status
{
	set tPayload = ..ReadBody(.tSC)
	set tAction = $select($$$ISOK(tSC):tPayload.action, 1:"")
	set tFeedback = $select($$$ISOK(tSC):tPayload.feedback, 1:"")
	set tSpecEdit = $select($$$ISOK(tSC):tPayload.specEdit, 1:"")
	// Fold any user-added plan items into one block.
	set tAdd = ""
	if $$$ISOK(tSC), $isobject(tPayload.planAdditions) {
		set it = tPayload.planAdditions.%GetIterator()
		while it.%GetNext(.k, .v) {
			set tv = $zstrip($select($isobject(v):"", 1:v), "<>W")
			if tv '= "" set tAdd = tAdd _ $select(tAdd'="":$char(10), 1:"") _ "- " _ tv
		}
	}
	set tSC = ##class(DTL.Service.JobManager).Continue(pId, tAction, tFeedback, .tcSC, tAdd, tSpecEdit)
	if $$$ISERR(tSC) || $$$ISERR(tcSC) {
		quit ..ErrJson(400, $system.Status.GetErrorText($select($$$ISERR(tSC):tSC, 1:tcSC)))
	}
	set tJob = ##class(DTL.Data.Job).OpenByJobId(pId, .sc)
	do ..Json(tJob.ToDynamic(1))
	quit $$$OK
}

/// POST /jobs/:id/refine - body {feedback}. Spawns a refinement job seeded with
/// the parent's DTL + feedback. Returns {jobId}.
ClassMethod RefineJob(pId As %String) As %Status
{
	set tPayload = ..ReadBody(.tSC)
	set tFeedback = $select($$$ISOK(tSC):tPayload.feedback, 1:"")
	if tFeedback = "" quit ..ErrJson(400, "feedback is required to refine")
	set tSC = ##class(DTL.Service.JobManager).Refine(pId, tFeedback, .tNewId, .trSC)
	if $$$ISERR(tSC) || $$$ISERR(trSC) {
		quit ..ErrJson(400, $system.Status.GetErrorText($select($$$ISERR(tSC):tSC, 1:trSC)))
	}
	set %response.Status = "202 Accepted"
	do ..Json({"jobId": (tNewId)})
	quit $$$OK
}

/// GET /jobs/:id/messages - the full LLM conversation (every message to/from the
/// model, in order) so the UI can show complete request/response visibility.
ClassMethod JobMessages(pId As %String) As %Status
{
	set tJob = ##class(DTL.Data.Job).OpenByJobId(pId, .sc)
	if '$isobject(tJob) quit ..ErrJson(404, "No job with id '" _ pId _ "'")
	do ..Json({"jobId": (pId), "messages": (tJob.TranscriptDynamic()), "usage": (tJob.UsageSummary())})
	quit $$$OK
}

/// GET /jobs/:id/outputs - all stored inputs transformed by the job's final DTL.
ClassMethod JobOutputs(pId As %String) As %Status
{
	do ..Json({"outputs": (##class(DTL.Service.JobManager).Outputs(pId))})
	quit $$$OK
}

/// POST /jobs/:id/transform - body {input}. Live: run the job's DTL on an
/// arbitrary input and return {output, error}.
ClassMethod JobTransform(pId As %String) As %Status
{
	set tPayload = ..ReadBody(.tSC)
	set tIn = $select($$$ISOK(tSC):tPayload.input, 1:"")
	if tIn = "" quit ..ErrJson(400, "input is required")
	set sc = ##class(DTL.Service.JobManager).Transform(pId, tIn, .tOut, .tErr)
	do ..Json({"output": (tOut), "error": ($select($$$ISOK(sc):"", 1:tErr))})
	quit $$$OK
}

/// POST /jobs/:id/correct - body {input, produced, corrected, feedback}. Feed the
/// correction back, rebuild the DTL, re-transform all inputs. Returns the job.
ClassMethod CorrectJob(pId As %String) As %Status
{
	set tPayload = ..ReadBody(.tSC)
	if $$$ISERR(tSC) quit ..ErrJson(400, "invalid JSON")
	set tSC = ##class(DTL.Service.JobManager).CorrectJob(pId, tPayload.input, tPayload.produced, tPayload.corrected, tPayload.feedback, .tcSC)
	if $$$ISERR(tSC) || $$$ISERR(tcSC) quit ..ErrJson(400, $system.Status.GetErrorText($select($$$ISERR(tSC):tSC, 1:tcSC)))
	set tJob = ##class(DTL.Data.Job).OpenByJobId(pId, .sc)
	do ..Json(tJob.ToDynamic(1))
	quit $$$OK
}

/// GET /classes - all DTL classes generated this session, with source.
ClassMethod Classes() As %Status
{
	do ..Json({"classes": (##class(DTL.Service.JobManager).Classes())})
	quit $$$OK
}

/// GET /history - all jobs newest-first with lineage (parentJobId), for the
/// History tab: the culmination of transformations + refinements.
ClassMethod History() As %Status
{
	set tArr = []
	set tStmt = ##class(%SQL.Statement).%New()
	set sc = tStmt.%Prepare("SELECT JobId,Status,Verdict,InputName,AttemptsUsed,FinalScore,Model,SessionId,ParentJobId,GeneratedClassName,UpdatedAt FROM DTL_Data.Job ORDER BY ID DESC")
	if $$$ISOK(sc) {
		set rs = tStmt.%Execute()
		while rs.%Next() {
			set o = {}
			set o.jobId = rs.%Get("JobId"), o.status = rs.%Get("Status"), o.verdict = rs.%Get("Verdict")
			set o.inputName = rs.%Get("InputName"), o.attemptsUsed = rs.%Get("AttemptsUsed")
			set o.finalScore = rs.%Get("FinalScore"), o.model = rs.%Get("Model")
			set o.sessionId = rs.%Get("SessionId"), o.parentJobId = rs.%Get("ParentJobId")
			set o.generatedClassName = rs.%Get("GeneratedClassName"), o.updatedAt = rs.%Get("UpdatedAt")
			do tArr.%Push(o)
		}
	}
	do ..Json({"history": (tArr)})
	quit $$$OK
}

/// GET /jobs - recent jobs, newest first.
ClassMethod ListJobs() As %Status
{
	set tArr = []
	set tStmt = ##class(%SQL.Statement).%New()
	set sc = tStmt.%Prepare("SELECT TOP 50 JobId,Status,Verdict,InputName,AttemptsUsed,FinalScore,UpdatedAt FROM DTL_Data.Job ORDER BY ID DESC")
	if $$$ISOK(sc) {
		set rs = tStmt.%Execute()
		while rs.%Next() {
			set o = {}
			set o.jobId = rs.%Get("JobId")
			set o.status = rs.%Get("Status")
			set o.verdict = rs.%Get("Verdict")
			set o.inputName = rs.%Get("InputName")
			set o.attemptsUsed = rs.%Get("AttemptsUsed")
			set o.finalScore = rs.%Get("FinalScore")
			set o.updatedAt = rs.%Get("UpdatedAt")
			do tArr.%Push(o)
		}
	}
	do ..Json({"jobs": (tArr)})
	quit $$$OK
}

// ---------------- helpers ----------------

/// Map a lowercase file extension to a content-type for serving the original upload.
ClassMethod MimeForExt(pExt As %String) As %String
{
	quit $case(pExt,
		"pdf":"application/pdf",
		"png":"image/png",
		"jpg":"image/jpeg",
		"jpeg":"image/jpeg",
		"gif":"image/gif",
		"webp":"image/webp",
		"txt":"text/plain",
		"md":"text/plain",
		"csv":"text/plain",
		"hl7":"text/plain",
		"docx":"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
		"doc":"application/msword",
		"html":"text/html",
		"htm":"text/html",
		:"application/octet-stream")
}

/// Parse the request body as JSON into a %DynamicObject.
ClassMethod ReadBody(Output pSC As %Status) As %DynamicObject
{
	set pSC = $$$OK
	try {
		set tObj = ##class(%DynamicAbstractObject).%FromJSON(%request.Content)
	} catch ex {
		set pSC = ex.AsStatus()
		set tObj = {}
	}
	quit tObj
}

/// Write a %DynamicObject as the JSON response body.
ClassMethod Json(pObj As %DynamicObject) As %Status
{
	set %response.ContentType = "application/json"
	write pObj.%ToJSON()
	quit $$$OK
}

/// Emit a JSON error with an HTTP status code.
ClassMethod ErrJson(pCode As %Integer, pMsg As %String) As %Status
{
	set %response.Status = pCode _ " " _ $case(pCode, 400:"Bad Request", 404:"Not Found", 503:"Service Unavailable", :"Error")
	set %response.ContentType = "application/json"
	write {"error": (pMsg), "code": (pCode)}.%ToJSON()
	quit $$$OK
}

}
