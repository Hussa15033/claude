/// Embedded-Python environment discovery + package installation, written so it
/// works regardless of OS (Windows / macOS / Linux) — every path is discovered
/// from IRIS itself rather than hardcoded.
///
/// Why this exists: `pip install pypdf` against the wrong interpreter (or a bare
/// `irispython` that isn't on PATH) leaves IRIS Embedded Python unable to import
/// the module ("No module named 'pypdf'"). The fix is to install INTO the
/// embedded interpreter's IRIS package directory (<ManagerDir>/python), which is
/// first on the embedded sys.path on every platform.
Class DTL.Util.Py Extends %RegisteredObject
{

/// The IRIS package directory that is first on Embedded Python's sys.path.
/// <install-mgr-dir>/python — exists on Windows/macOS/Linux alike.
ClassMethod LibDir() As %String
{
	quit ##class(%File).NormalizeDirectory("python", ##class(%File).ManagerDirectory())
}

/// The interpreter Embedded Python uses. We prefer the platform-typical
/// `irispython` next to the IRIS bin dir, then a configured value, then common
/// names — all discovered, none hardcoded. (We deliberately AVOID asking the
/// in-process embedded interpreter, since %SYS.Python calls can destabilize the
/// instance; everything here stays out-of-process.)
ClassMethod Executable() As %String
{
	set cfg = $get(^DTL.Config("pythonExe"))
	if cfg '= "", ##class(%File).Exists(cfg) quit cfg
	set tBin = $system.Util.BinaryDirectory()    // e.g. /usr/irissys/bin/  (cross-OS)
	for c = tBin_"irispython", tBin_"irispython.exe", tBin_"python", tBin_"python.exe", "/usr/bin/python3", "python3", "python" {
		if ##class(%File).Exists(c) quit
	}
	quit $select($get(c)'="" && ##class(%File).Exists(c):c, 1:"python3")
}

/// Ensure the given packages (space-separated) are importable by Embedded Python;
/// install any that are missing into LibDir() via the discovered interpreter.
/// Returns 1 if all are importable afterwards. pLog (byref) collects a short note.
/// Runs pip OUT OF PROCESS via $ZF(-100) so it never destabilises the instance.
ClassMethod EnsurePackages(pPackages As %String = "pypdf python-docx", ByRef pLog As %String) As %Boolean
{
	set pLog = ""
	// Build the import-name list (pypdf->pypdf, python-docx->docx).
	set tImports = $replace(pPackages, "python-docx", "docx")
	if ..CanImport(tImports) { set pLog = "already present" quit 1 }

	set tLib = ..LibDir()
	if '##class(%File).DirectoryExists(tLib) do ##class(%File).CreateDirectoryChain(tLib)
	set tExe = ..Executable()
	set tOut = ##class(%File).TempFilename("txt")
	// Build one pip command string and run it through the OS shell. (Passing
	// `-m pip install ...` as separate $ZF(-100) varargs to python proved
	// unreliable -- it returned instantly without running -- whereas a single
	// shell command string runs synchronously and waits.)
	set tCmd = ..Quote(tExe) _ " -m pip install --target " _ ..Quote(tLib) _ " --upgrade --disable-pip-version-check " _ pPackages
	if ..IsWindows() {
		set tRC = $ZF(-100, "/SHELL/STDOUT=""" _ tOut _ """", "cmd", "/c", tCmd _ " > """ _ tOut _ """ 2>&1")
	} else {
		set tRC = $ZF(-100, "/SHELL", "/bin/sh", "-c", tCmd _ " > " _ ..Quote(tOut) _ " 2>&1")
	}
	set tMsg = ..ReadFile(tOut)
	do ##class(%File).Delete(tOut)

	set tOk = ..CanImport(tImports)
	set pLog = $select(tOk:"installed into " _ tLib, 1:"install FAILED (rc=" _ tRC _ "): " _ $extract(tMsg, 1, 400))
	quit tOk
}

/// True on Windows.
ClassMethod IsWindows() As %Boolean
{
	quit ($zconvert($system.Version.GetOS(), "U") [ "WIN")
}

/// Shell-quote a path/value for the target OS.
ClassMethod Quote(pVal As %String) As %String
{
	if ..IsWindows() quit """" _ pVal _ """"
	quit "'" _ $replace(pVal, "'", "'\''") _ "'"
}

/// True if every comma/space-separated module name imports under the SUBPROCESS
/// interpreter (the same one DocExtract uses). Runs out-of-process via $ZF(-100)
/// so it never touches in-process Embedded Python (which can wedge the instance).
/// The interpreter's sys.path includes the IRIS <mgr>/python dir we install into.
ClassMethod CanImport(pModules As %String) As %Boolean
{
	set tNames = $zstrip($replace($replace(pModules, ",", " "), "  ", " "), "<>W")
	set tOut = ##class(%File).TempFilename("txt")
	// python -c "import a, b; open(out,'w').write('1')"
	set tImports = "import " _ $replace(tNames, " ", ", ")
	set tPy = tImports _ "; open(" _ ..Q(tOut) _ ",'w').write('1')"
	set tExe = ..Executable()
	if ..IsWindows() {
		do $ZF(-100, "/SHELL", "cmd", "/c", ..Quote(tExe) _ " -c " _ """" _ tPy _ """")
	} else {
		do $ZF(-100, "/SHELL", "/bin/sh", "-c", ..Quote(tExe) _ " -c " _ ..Quote(tPy))
	}
	set tOk = (##class(%File).Exists(tOut)) && (..ReadFile(tOut) = "1")
	do:##class(%File).Exists(tOut) ##class(%File).Delete(tOut)
	quit tOk
}

ClassMethod ReadFile(pPath As %String) As %String
{
	quit:'##class(%File).Exists(pPath) ""
	set s = ##class(%Stream.FileCharacter).%New()
	do s.LinkToFile(pPath)
	set t = "" while 's.AtEnd { set t = t _ s.Read(16000) }
	quit t
}

/// Python single-quoted string literal.
ClassMethod Q(pVal As %String) As %String
{
	quit "'" _ $replace($replace(pVal, "\", "\\"), "'", "\'") _ "'"
}

}
