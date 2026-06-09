/// Initialization / health test hook for the whole DTL GenAI framework.
///
/// Verifies that every moving part is present and correctly initialized:
///   - all framework classes compiled
///   - the production is running with every expected item
///   - the LLM endpoint (mock or OpenAI) is reachable
///   - the HL7 schema library is installed
///   - the REST web applications are registered
///   - the runtime data directories exist
///
/// Use from the terminal:   do ##class(DTL.Test.HealthCheck).Run()
/// Use from REST (/health):  set j = ##class(DTL.Test.HealthCheck).RunJSON()
Class DTL.Test.HealthCheck Extends %RegisteredObject
{

/// Run all checks and print a human-readable report; returns 1 if all pass.
ClassMethod Run() As %Boolean
{
	set tRes = ..RunJSON()
	write "==== DTL Framework Health Check ====", !
	set it = tRes.checks.%GetIterator()
	while it.%GetNext(.k, .c) {
		write $select(c.ok:"  [ OK ] ", 1:"  [FAIL] "), c.name
		if c.detail '= "" write "  -- ", c.detail
		write !
	}
	write "------------------------------------", !
	write $select(tRes.ok:"ALL CHECKS PASSED", 1:"SOME CHECKS FAILED"), " (", tRes.passed, "/", tRes.total, ")", !
	quit tRes.ok
}

/// Run all checks and return a structured %DynamicObject:
///   { ok, passed, total, checks:[ {name, ok, detail}, ... ] }
ClassMethod RunJSON() As %DynamicObject
{
	set tChecks = []
	set tAllOk = 1

	// 1. Classes compiled.
	set tMissing = ""
	for cls = "DTL.Util.Verifier", "DTL.Util.HL7", "DTL.Util.Extractor", "DTL.Util.PromptBuilder", "DTL.Proc.Orchestrator", "DTL.Op.LLMConnector", "DTL.Svc.PairFileService", "DTL.Msg.ForgeRequest", "DTL.Data.Job", "DTL.Service.JobManager", "DTL.REST.Dispatch", "DTL.Setup.Production" {
		if '##class(%Dictionary.CompiledClass).%ExistsId(cls) set tMissing = tMissing _ $select(tMissing'="":", ",1:"") _ cls
	}
	do ..Add(tChecks, "Framework classes compiled", (tMissing = ""), $select(tMissing="":"all present", 1:"missing: " _ tMissing), .tAllOk)

	// 2. Production running with expected items.
	set tProdOk = ##class(Ens.Director).IsProductionRunning()
	set tProdDetail = ""
	if tProdOk {
		do ##class(Ens.Director).GetProductionStatus(.tName, .tState)
		set tProdDetail = tName
		// confirm each expected item is enabled/running
		set tItemsMissing = ""
		for item = "DTL.Svc.PairFileService", "DTL.Proc.Orchestrator", "DTL.Op.LLMConnector" {
			if '##class(Ens.Director).IsItemEnabled(item) set tItemsMissing = tItemsMissing _ $select(tItemsMissing'="":", ",1:"") _ item
		}
		if tItemsMissing '= "" set tProdOk = 0, tProdDetail = tProdDetail _ " (items down: " _ tItemsMissing _ ")"
	} else {
		set tProdDetail = "no production running"
	}
	do ..Add(tChecks, "Production running", tProdOk, tProdDetail, .tAllOk)

	// 3. LLM endpoint reachable (mock or openai), via a tiny GET to /health-ish.
	set tLLMOk = ..PingLLM(.tLLMDetail)
	do ..Add(tChecks, "LLM endpoint reachable", tLLMOk, tLLMDetail, .tAllOk)

	// 4. HL7 schemas installed.
	set tSchema = $get(^EnsHL7.Schema("2.5"))
	set tHasSchema = (##class(EnsLib.HL7.Schema).ResolveSchemaTypeToDocType("2.5", "ADT_A01") '= "")
	do ..Add(tChecks, "HL7 schema library installed", tHasSchema, $select(tHasSchema:"2.x schemas resolve", 1:"EnsLib.HL7 schemas missing"), .tAllOk)

	// 5. REST web apps registered.
	set tApiOk = ..WebAppExists("/dtl/api", .tApiDetail)
	do ..Add(tChecks, "REST app /dtl/api registered", tApiOk, tApiDetail, .tAllOk)
	set tUiOk = ..WebAppExists("/dtl/ui", .tUiDetail)
	do ..Add(tChecks, "UI app /dtl/ui registered", tUiOk, tUiDetail, .tAllOk)

	// 6. Data directories present.
	set tData = ##class(DTL.Setup.Installer).DataDir()
	set tDirsOk = 1, tDirsMissing = ""
	for sub = "inputs", "outputs", "archive", "results" {
		set d = ##class(DTL.Setup.Installer).JoinDir(tData, sub)
		if '##class(%File).DirectoryExists(d) set tDirsOk = 0, tDirsMissing = tDirsMissing _ sub _ " "
	}
	do ..Add(tChecks, "Runtime data directories", tDirsOk, $select(tDirsOk:tData, 1:"missing: " _ tDirsMissing), .tAllOk)

	// 7. End-to-end smoke: compile + run a known reference DTL (proves the core).
	set tSmokeOk = ..SmokeTransform(.tSmokeDetail)
	do ..Add(tChecks, "DTL compile+transform smoke test", tSmokeOk, tSmokeDetail, .tAllOk)

	set tPassed = 0
	set it = tChecks.%GetIterator()
	while it.%GetNext(.k, .c) { if c.ok set tPassed = tPassed + 1 }

	set tOut = {}
	set tOut.ok = tAllOk
	set tOut.passed = tPassed
	set tOut.total = tChecks.%Size()
	set tOut.checks = tChecks
	quit tOut
}

/// Ping the configured LLM endpoint with a trivial request. Reachable = the
/// HTTP server answered (any status), since auth/route may legitimately 404/401.
ClassMethod PingLLM(Output pDetail As %String) As %Boolean
{
	set pDetail = ""
	try {
		// Read host/port from the running LLMConnector item settings if possible,
		// else default to the mock on localhost:8085.
		set tHost = "localhost", tPort = 8085
		set tDef = ##class(Ens.Config.Production).%OpenId("DTL.Setup.Production")
		if $isobject(tDef) {
			for i = 1:1:tDef.Items.Count() {
				set it = tDef.Items.GetAt(i)
				continue:it.Name'="DTL.Op.LLMConnector"
				for j = 1:1:it.Settings.Count() {
					set s = it.Settings.GetAt(j)
					if s.Name = "HTTPServer", s.Value '= "" set tHost = s.Value
					if s.Name = "HTTPPort", s.Value '= "" set tPort = s.Value
				}
			}
		}
		set http = ##class(%Net.HttpRequest).%New()
		set http.Server = tHost, http.Port = tPort, http.Timeout = 5
		set sc = http.Get("/health")
		if $$$ISOK(sc) {
			set pDetail = tHost _ ":" _ tPort _ " (HTTP " _ http.HttpResponse.StatusCode _ ")"
			return 1
		}
		// Some endpoints have no /health; a connection-level success still counts.
		set pDetail = tHost _ ":" _ tPort _ " unreachable: " _ $system.Status.GetErrorText(sc)
		return 0
	} catch ex {
		set pDetail = ex.DisplayString()
		return 0
	}
}

/// True if a CSP web application with the given name exists (checked in %SYS).
ClassMethod WebAppExists(pName As %String, Output pDetail As %String) As %Boolean
{
	set pDetail = ""
	new $namespace
	set tOk = 0
	try {
		set $namespace = "%SYS"
		set tOk = ##class(Security.Applications).Exists(pName)
		set pDetail = $select(tOk:pName, 1:"not registered")
	} catch ex {
		set pDetail = ex.DisplayString()
	}
	quit tOk
}

/// Compile + run a reference DTL against its input and check it matches output.
ClassMethod SmokeTransform(Output pDetail As %String) As %Boolean
{
	set pDetail = ""
	try {
		set tBase = ##class(DTL.Setup.Installer).ResolveSrcDir($get(^DTL.Config("srcDir")))
		if tBase = "" { set pDetail = "source dir not resolved" return 0 }
		set tFrag = ##class(DTL.Setup.Installer).ReadFile(tBase _ "reference/ADT_A01_Admit.dtl.xml")
		set tIn = ##class(DTL.Setup.Installer).ReadFile(tBase _ "inputs/ADT_A01_Admit.hl7")
		set tOut = ##class(DTL.Setup.Installer).ReadFile(tBase _ "outputs/ADT_A01_Admit.hl7")
		if (tFrag = "") || (tIn = "") || (tOut = "") { set pDetail = "reference files missing" return 0 }
		set tCls = "DTL.Generated.HealthSmoke"
		set tRes = ##class(DTL.Util.Verifier).VerifyAll(tFrag, tIn, tOut, "2.3:ADT_A01", "CompileMatch", .tCls)
		if ##class(%Dictionary.CompiledClass).%ExistsId(tCls) do $system.OBJ.Delete(tCls, "-d")
		set tOk = (tRes.compiled && tRes.ran && tRes.matched)
		set pDetail = $select(tOk:"ADT_A01 reference verified (score " _ $fnumber(tRes.score, "", 3) _ ")", 1:"verify failed: " _ $get(tRes.compileErrors))
		return tOk
	} catch ex {
		set pDetail = ex.DisplayString()
		return 0
	}
}

ClassMethod Add(pArr As %DynamicArray, pName As %String, pOk As %Boolean, pDetail As %String, ByRef pAllOk As %Boolean)
{
	set c = {}
	set c.name = pName
	set c.ok = ''pOk
	set c.detail = pDetail
	do pArr.%Push(c)
	if 'pOk set pAllOk = 0
}

}
