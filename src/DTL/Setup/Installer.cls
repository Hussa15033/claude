/// One-shot installer for the DTL GenAI framework. Loads + compiles all source,
/// prepares the runtime data directories, wires their (derived) paths into the
/// production, and (optionally) starts it.
///
///   do ##class(DTL.Setup.Installer).Run()              ; auto-discovers the source dir
///   do ##class(DTL.Setup.Installer).Run("dtlsrc")      ; source dir relative to cwd/HOME/mgr
///   do ##class(DTL.Setup.Installer).Run("/abs/path")   ; explicit absolute source dir
///
/// No paths are hardcoded: the runtime data directory is derived from the IRIS
/// manager directory, and the source directory is auto-discovered from a small
/// set of conventional relative locations (or passed in). Idempotent; pass
/// pStart=0 to load without starting.
Class DTL.Setup.Installer Extends %RegisteredObject
{

/// Name of the runtime data subdirectory (created under the manager directory by
/// default). Holds inputs/ outputs/ archive/ results/.
Parameter DATASUBDIR = "dtldata";

/// Conventional source-directory names to probe when none is given. Each is
/// resolved relative to the manager dir, the home dir, and the current dir.
Parameter SRCCANDIDATES = "dtlsrc,dtl-genai,src";

ClassMethod Run(pSrcDir As %String = "", pStart As %Boolean = 1, pDataDir As %String = "") As %Status
{
	set tSC = $$$OK
	try {
		write "== DTL GenAI Installer ==", !

		// 0. Resolve the source directory (relative-friendly, auto-discovered).
		set tSrc = ..ResolveSrcDir(pSrcDir)
		if tSrc = "" {
			set tSC = $$$ERROR($$$GeneralError, "Could not locate a source directory containing DTL/. Pass it explicitly: do ##class(DTL.Setup.Installer).Run(""/path/to/dtlsrc"")")
			write "  ", $system.Status.GetErrorText(tSC), !
			quit
		}
		write "Source dir: ", tSrc, !

		// 1. Load + compile all classes.
		write "Loading classes from ", tSrc, "/DTL ...", !
		set tSC = $system.OBJ.LoadDir(tSrc _ "/DTL", "ck/displayerror=0/displaylog=0/recurse=1", .err, 1)
		if $$$ISERR(tSC) {
			write "  LOAD FAILED: ", $system.Status.GetErrorText(tSC), !
			quit
		}
		write "  classes compiled OK", !

		// 2. Prepare data directories (derived) + seed example data.
		set tData = ..DataDir(pDataDir)
		// Record the resolved dirs EARLY so service OnInit() (which derives its
		// watched FilePath from ^DTL.Config("dataDir")) always has them, even if a
		// later step is slow or fails.
		set ^DTL.Config("srcDir") = tSrc
		set ^DTL.Config("dataDir") = tData
		do ..PrepareDataDirs(tSrc, tData)

		// 3. Wire the derived data paths into the production items.
		do ..ConfigureProductionPaths(tData)

		// 3b. Create the CSP web applications (REST API + static UI) and deploy SPA.
		do ..SetupWebApps(tSrc)

		// 3c. Deploy the python extraction helper + record interpreter/dirs (fast).
		//     The (potentially slow) pip install of pypdf/python-docx is done AFTER
		//     the production starts so it never delays bringing the system up.
		do ..SetupDocExtraction(tSrc)

		// 4. Start the production.
		if pStart {
			write "Starting production DTL.Setup.Production ...", !
			set tSC = ##class(Ens.Director).StartProduction("DTL.Setup.Production")
			if $$$ISERR(tSC) {
				set tTxt = $system.Status.GetErrorText(tSC)
				if (tTxt [ "already running") || (tTxt [ "5001") {
					write "  (a production is already running; applying updated settings)", !
					do ##class(Ens.Director).UpdateProduction()
					set tSC = $$$OK
				} else {
					write "  START FAILED: ", tTxt, !
					quit
				}
			} else {
				write "  production started", !
			}
		}
		// 5. Ensure the python extraction libs — done LAST so the slow pip install
		//    never blocks the system coming up. Out-of-process. Markdown conversion
		//    uses pypandoc (docx/html/...) + pdfplumber (pdf tables); pypdf is the
		//    PDF fallback.
		set tPyOk = ##class(DTL.Util.Py).EnsurePackages("pypdf pdfplumber pypandoc python-docx", .tPyLog)
		write "  python libs (pypdf, pdfplumber, pypandoc, python-docx): ", $select(tPyOk:"OK", 1:"NOT AVAILABLE"), " — ", tPyLog, !
		write "== Done ==", !
	} catch ex {
		set tSC = ex.AsStatus()
		write "INSTALLER EXCEPTION: ", ex.DisplayString(), !
	}
	quit tSC
}

/// Derive the runtime data directory. If pDataDir is given it is used (resolved
/// relative to the manager dir when not absolute); otherwise <DATASUBDIR> under
/// the IRIS manager directory -- always present and writable, never hardcoded.
ClassMethod DataDir(pDataDir As %String = "") As %String
{
	if pDataDir '= "" {
		// Absolute path used as-is; relative resolved under the manager directory.
		if ..IsAbsolute(pDataDir) quit ##class(%File).NormalizeDirectory(pDataDir)
		quit ..JoinDir(##class(%File).ManagerDirectory(), pDataDir)
	}
	quit ..JoinDir(##class(%File).ManagerDirectory(), ..#DATASUBDIR)
}

/// True if pPath is an absolute path (POSIX / or Windows drive/UNC).
ClassMethod IsAbsolute(pPath As %String) As %Boolean
{
	quit:pPath="" 0
	quit ($extract(pPath) = "/") || ($extract(pPath) = "\") || ($extract(pPath, 2) = ":")
}

/// Resolve the source directory containing a DTL/ subfolder. Accepts an explicit
/// path (absolute or relative), else probes conventional locations relative to
/// the manager dir, the process home dir, and the current dir.
ClassMethod ResolveSrcDir(pSrcDir As %String = "") As %String
{
	// Explicit value: try as-is (if absolute), then relative to manager dir, home
	// dir and cwd.
	if pSrcDir '= "" {
		set tTry = ""
		if ..IsAbsolute(pSrcDir) set tTry = tTry _ $listbuild(##class(%File).NormalizeDirectory(pSrcDir))
		set tTry = tTry _ $listbuild(
			..JoinDir(##class(%File).ManagerDirectory(), pSrcDir),
			..JoinDir(..HomeDir(), pSrcDir),
			..JoinDir(##class(%File).NormalizeDirectory(""), pSrcDir))
		set ptr = 0
		while $listnext(tTry, ptr, tDir) {
			set tResolved = ..DTLBase(tDir)
			if tResolved '= "" quit
		}
		quit:$get(tResolved)'="" tResolved
		// fall through to auto-discovery if the explicit one didn't pan out
	}

	// Auto-discovery: <candidate> under [manager dir, home dir, cwd].
	set tRoots = $listbuild(##class(%File).ManagerDirectory(), ..HomeDir(), ##class(%File).NormalizeDirectory(""))
	set tCands = $listfromstring(..#SRCCANDIDATES, ",")
	set rptr = 0
	while $listnext(tRoots, rptr, tRoot) {
		continue:tRoot=""
		set cptr = 0
		while $listnext(tCands, cptr, tCand) {
			set tResolved = ..DTLBase(..JoinDir(tRoot, tCand))
			if tResolved '= "" quit
		}
		if $get(tResolved)'="" quit
	}
	quit $get(tResolved)
}

/// Given a candidate directory, return the directory that actually CONTAINS the
/// DTL/ subfolder, tolerating a nested src/ layer (e.g. a 'src/.'-mangled copy
/// that lands the tree at <dir>/src/DTL instead of <dir>/DTL). "" if neither.
ClassMethod DTLBase(pDir As %String) As %String
{
	quit:pDir="" ""
	if ##class(%File).DirectoryExists(..JoinDir(pDir, "DTL")) quit ##class(%File).NormalizeDirectory(pDir)
	set tNested = ..JoinDir(pDir, "src")
	if ##class(%File).DirectoryExists(..JoinDir(tNested, "DTL")) quit tNested
	quit ""
}

/// True if pDir (or pDir/src) contains a DTL/ subdirectory.
ClassMethod HasDTL(pDir As %String) As %Boolean
{
	quit ..DTLBase(pDir) '= ""
}

/// The process's home directory (from $HOME), normalized; "" if unset.
ClassMethod HomeDir() As %String
{
	set h = $system.Util.GetEnviron("HOME")
	quit:h="" ""
	quit ##class(%File).NormalizeDirectory(h)
}

/// Join a subdirectory onto a parent directory, returning a normalized directory
/// path. (The 2-arg %File.NormalizeDirectory(rel,base) is unreliable when base is
/// not already normalized, so we concatenate then single-arg normalize.)
ClassMethod JoinDir(pParent As %String, pSub As %String) As %String
{
	quit ##class(%File).NormalizeDirectory(##class(%File).NormalizeDirectory(pParent) _ pSub)
}

/// Apply the derived data-dir paths to the production's item settings, so the
/// Production class itself carries NO hardcoded absolute paths.
ClassMethod ConfigureProductionPaths(pDataDir As %String)
{
	set d = ##class(%File).NormalizeDirectory(pDataDir)
	do ##class(Ens.Director).SetItemSettingValue("DTL.Svc.PairFileService", "Adapter", "FilePath", ..JoinDir(d, "inputs"))
	do ##class(Ens.Director).SetItemSettingValue("DTL.Svc.PairFileService", "Adapter", "ArchivePath", ..JoinDir(d, "archive"))
	do ##class(Ens.Director).SetItemSettingValue("DTL.Svc.PairFileService", "Host", "OutputsPath", ..JoinDir(d, "outputs"))
	do ##class(Ens.Director).SetItemSettingValue("DTL.Proc.Orchestrator", "Host", "ArtifactDir", ..JoinDir(d, "results"))
	// Spec-document upload service watches specs/ and archives to specsarchive/.
	do ##class(Ens.Director).SetItemSettingValue("DTL.Svc.SpecFileService", "Adapter", "FilePath", ..JoinDir(d, "specs"))
	do ##class(Ens.Director).SetItemSettingValue("DTL.Svc.SpecFileService", "Adapter", "ArchivePath", ..JoinDir(d, "specsarchive"))
	set ^DTL.Config("specsDir") = ..JoinDir(d, "specs")
	write "  production paths set to ", d, !
}

/// Deploy the python text-extraction helper, record its directory, and best-effort
/// ensure pypdf + python-docx are installed for IRIS Embedded Python.
ClassMethod SetupDocExtraction(pSrcDir As %String)
{
	// Deploy dtl_extract.py next to the manager dir (a stable, writable location).
	set tDir = ##class(%File).ManagerDirectory()
	set tSrcPy = ##class(%File).NormalizeFilename("dtl_extract.py", ..JoinDir(##class(%File).NormalizeDirectory(pSrcDir), "mock"))
	if ##class(%File).Exists(tSrcPy) {
		do ##class(%File).CopyFile(tSrcPy, ##class(%File).NormalizeFilename("dtl_extract.py", tDir))
	}
	set ^DTL.Config("pyDir") = tDir
	// Record the embedded-python interpreter (discovered from IRIS, cross-OS) for
	// the extraction subprocess. (The actual pip install of pypdf/python-docx is
	// done by Run() AFTER the production starts, so the slow step never blocks.)
	set ^DTL.Config("pythonExe") = ##class(DTL.Util.Py).Executable()
	write "  doc extraction ready (helper at ", tDir, "dtl_extract.py, python ", $get(^DTL.Config("pythonExe")), ", libdir ", ##class(DTL.Util.Py).LibDir(), ")", !
}

/// Create the CSP web applications and deploy the SPA. Two apps:
///   /dtl/api  -> REST, dispatched by DTL.REST.Dispatch (namespace USER)
///   /dtl/ui   -> static files, serving index.html (the SPA) from a physical dir
/// Must run in %SYS (uses Security.Applications); we switch namespace internally.
/// pSrcDir is the framework source dir (the SPA lives at <src>/ui/index.html).
/// Create the CSP web applications and deploy the SPA.
///
/// IMPORTANT: Security.Applications/Security.Users are visible only in %SYS, while
/// THIS class is compiled in USER. So we must NOT call sibling DTL.* methods after
/// switching to %SYS (the class isn't resolvable there). All Security.* work is
/// therefore done INLINE in this single method, bracketed by zn "%SYS"/zn back.
ClassMethod SetupWebApps(pSrcDir As %String)
{
	set tNs = $namespace
	set tUiPhysical = ..JoinDir(##class(%File).ManagerDirectory(), "csp") _ "dtlui" _ "/"
	// Ensure the UI physical dir exists and deploy the SPA into it (USER context).
	if '##class(%File).DirectoryExists(tUiPhysical) do ##class(%File).CreateDirectoryChain(tUiPhysical)
	set tSpaSrc = ##class(%File).NormalizeFilename("index.html", ..JoinDir(##class(%File).NormalizeDirectory(pSrcDir), "ui"))
	if ##class(%File).Exists(tSpaSrc) {
		do ##class(%File).CopyFile(tSpaSrc, ##class(%File).NormalizeFilename("index.html", tUiPhysical))
	}

	// All security configuration must happen in %SYS, inline.
	new $namespace
	set $namespace = "%SYS"

	// --- REST app /dtl/api (DispatchClass + unauthenticated) ---
	kill tApi
	set tApi("NameSpace") = tNs
	set tApi("DispatchClass") = "DTL.REST.Dispatch"
	set tApi("AutheEnabled") = 64   // 64 = unauthenticated access (demo convenience)
	set tApi("Enabled") = 1
	set tApi("CookiePath") = "/dtl/api/"
	set tApi("Description") = "DTL GenAI REST API"
	set tApiSC = $$$OK
	if ##class(Security.Applications).Exists("/dtl/api") {
		set tApiSC = ##class(Security.Applications).Modify("/dtl/api", .tApi)
	} else {
		set tApiSC = ##class(Security.Applications).Create("/dtl/api", .tApi)
	}
	// Some versions ignore AutheEnabled on Create -- enforce it with a follow-up Modify.
	kill tFix set tFix("AutheEnabled") = 64
	do ##class(Security.Applications).Modify("/dtl/api", .tFix)

	// --- static UI app /dtl/ui ---
	kill tUi
	set tUi("NameSpace") = tNs
	set tUi("Path") = tUiPhysical
	set tUi("AutheEnabled") = 64
	set tUi("Enabled") = 1
	set tUi("ServeFiles") = 2        // 2 = serve static files (per /csp/user)
	set tUi("ServeFilesTimeout") = 3600
	set tUi("CSPZENEnabled") = 1
	set tUi("Description") = "DTL GenAI UI (static SPA)"
	set tUiSC = $$$OK
	if ##class(Security.Applications).Exists("/dtl/ui") {
		set tUiSC = ##class(Security.Applications).Modify("/dtl/ui", .tUi)
	} else {
		set tUiSC = ##class(Security.Applications).Create("/dtl/ui", .tUi)
	}
	kill tFix set tFix("AutheEnabled") = 64
	do ##class(Security.Applications).Modify("/dtl/ui", .tFix)

	// --- DEMO ONLY: give the UnknownUser the roles needed for unauthenticated
	//     access to the namespace. Remove/restrict for shared or production hosts. ---
	if ##class(Security.Users).Exists("UnknownUser") {
		do ##class(Security.Users).Get("UnknownUser", .tU)
		set tRoles = $get(tU("Roles"))
		if tRoles '[ "%All" {
			kill tM set tM("Roles") = $select(tRoles="":"%All", 1:tRoles _ ",%All")
			do ##class(Security.Users).Modify("UnknownUser", .tM)
		}
	}

	// --- TLS client config for the HTTPS OpenAI connection (idempotent). ---
	if ##class(%Dictionary.CompiledClass).%ExistsId("Security.SSLConfigs") {
		if '##class(Security.SSLConfigs).Exists("DTLOpenAISSL") {
			do ##class(Security.SSLConfigs).Create("DTLOpenAISSL")
		}
	}

	zn tNs
	write "  web apps ready: /dtl/api (REST, sc=", $$$ISOK(tApiSC), ") and /dtl/ui (SPA at ", tUiPhysical, ")", !
	write "  SSL config 'DTLOpenAISSL' ready for OpenAI HTTPS", !
}

/// Create the runtime data directory tree and copy example inputs/outputs in.
ClassMethod PrepareDataDirs(pSrcDir As %String, pDataDir As %String)
{
	set tBase = ##class(%File).NormalizeDirectory(pDataDir)
	if '##class(%File).DirectoryExists(tBase) do ##class(%File).CreateDirectoryChain(tBase)
	for sub = "inputs", "outputs", "archive", "results", "specs", "specsarchive" {
		set tDir = ..JoinDir(tBase, sub)
		if '##class(%File).DirectoryExists(tDir) {
			do ##class(%File).CreateDirectoryChain(tDir)
		}
	}
	// Copy example outputs (so the service can find matching expected outputs).
	do ..CopyDir(..JoinDir(##class(%File).NormalizeDirectory(pSrcDir), "outputs"), ..JoinDir(tBase, "outputs"))
	// Clear any stale result artifacts from prior runs.
	set rs = ##class(%ResultSet).%New("%File:FileSet")
	do rs.Execute(..JoinDir(tBase, "results"), "*")
	while rs.Next() { do ##class(%File).Delete(rs.GetData(1)) }
	write "  data dirs ready under ", tBase, !
	write "  drop an input .hl7 into ", ..JoinDir(tBase, "inputs"), " to trigger a job", !
}

/// Copy *.hl7 files from one dir to another.
ClassMethod CopyDir(pFrom As %String, pTo As %String)
{
	quit:'##class(%File).DirectoryExists(pFrom)
	set rs = ##class(%ResultSet).%New("%File:FileSet")
	do rs.Execute(pFrom, "*.hl7")
	while rs.Next() {
		set tName = rs.GetData(1)
		set tBase = ##class(%File).GetFilename(tName)
		do ##class(%File).CopyFile(tName, ##class(%File).NormalizeFilename(tBase, pTo))
	}
}

/// Convenience: run one forge job for a named example pair by injecting a
/// ForgeRequest into the RUNNING production's orchestrator via the built-in
/// EnsLib.Testing.Service, and print the result. pSrcDir defaults to the source
/// dir resolved by the last Run() (stored in ^DTL.Config), else auto-discovery.
ClassMethod ForgeExample(pName As %String, pSrcDir As %String = "", pMaxAttempts As %Integer = 5, pPolicy As %String = "CompileMatch") As %Status
{
	if pSrcDir = "" set pSrcDir = $get(^DTL.Config("srcDir"))
	set pSrcDir = ..ResolveSrcDir(pSrcDir)
	set tIn = ..ReadFile(##class(%File).NormalizeFilename(pName _ ".hl7", ..JoinDir(pSrcDir, "inputs")))
	set tOut = ..ReadFile(##class(%File).NormalizeFilename(pName _ ".hl7", ..JoinDir(pSrcDir, "outputs")))
	if (tIn = "") || (tOut = "") {
		write "Missing input/output for ", pName, " under ", pSrcDir, !
		quit $$$ERROR($$$GeneralError, "missing pair")
	}
	set tReq = ##class(DTL.Msg.ForgeRequest).%New()
	set tReq.JobId = pName
	set tReq.InputName = pName
	do tReq.SourceHL7.Write(tIn)
	do tReq.TargetHL7.Write(tOut)
	set tReq.SourceDocType = ##class(DTL.Util.HL7).DeriveDocType(tIn)
	set tReq.TargetDocType = ##class(DTL.Util.HL7).DeriveDocType(tOut)
	set tReq.MaxAttempts = pMaxAttempts
	set tReq.SuccessPolicy = pPolicy

	quit ..Dispatch(tReq)
}

/// Inject a ForgeRequest into the orchestrator BP through the testing service and
/// print the ForgeResponse. Requires the production to be running.
ClassMethod Dispatch(pReq As DTL.Msg.ForgeRequest, pTarget As %String = "DTL.Proc.Orchestrator") As %Status
{
	set tSC = ##class(Ens.Director).CreateBusinessService("EnsLib.Testing.Service", .tSvc)
	if $$$ISERR(tSC) {
		write "Could not create testing service (is the production running?): ", $system.Status.GetErrorText(tSC), !
		quit tSC
	}
	set tSC = tSvc.SendRequestSync(pTarget, pReq, .tResp, 300)
	if $$$ISERR(tSC) {
		write "Dispatch failed: ", $system.Status.GetErrorText(tSC), !
		quit tSC
	}
	if $isobject($get(tResp)) {
		write "Job ", tResp.JobId, ": success=", tResp.Success, " verdict=", tResp.Verdict, " attempts=", tResp.AttemptsUsed, " score=", $fnumber(tResp.FinalScore, "", 3), !
		write "  generated class: ", tResp.GeneratedClassName, !
		set tDiff = ..StreamStr(tResp.DiffSummary)
		if tDiff '= "" write "  remaining diffs:", !, tDiff, !
	}
	quit tSC
}

ClassMethod StreamStr(pStream As %Stream.Object) As %String
{
	quit:'$isobject(pStream) ""
	do pStream.Rewind()
	set s = ""
	while 'pStream.AtEnd { set s = s _ pStream.Read(16000) }
	quit s
}

ClassMethod ReadFile(pPath As %String) As %String
{
	quit:'##class(%File).Exists(pPath) ""
	set f = ##class(%Stream.FileCharacter).%New()
	do f.LinkToFile(pPath)
	quit f.Read(3600000)
}

}
