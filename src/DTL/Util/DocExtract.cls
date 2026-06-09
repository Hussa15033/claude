/// Extracts plain text from an uploaded specification document (.pdf, .docx,
/// .txt/.md/.hl7/anything-textual).
///
/// IMPORTANT (hard-won gotcha): doing this with IN-PROCESS Embedded Python
/// (%SYS.Python.Import/.Run) repeatedly SIGSEGV'd the IRIS call-in process and
/// even wedged the whole instance / CSP gateway. So extraction is delegated to an
/// `irispython` OS SUBPROCESS via $ZF(-100), capturing stdout to a temp file.
/// This is completely stable and isolates any Python crash to a child process.
Class DTL.Util.DocExtract Extends %RegisteredObject
{

/// Directory holding dtl_extract.py (set by the installer in ^DTL.Config("pyDir");
/// falls back to the IRIS manager directory).
ClassMethod HelperDir() As %String
{
	set d = $get(^DTL.Config("pyDir"))
	quit $select(d'="":d, 1:##class(%File).ManagerDirectory())
}

/// Path to the irispython executable.
ClassMethod PythonExe() As %String
{
	set p = $get(^DTL.Config("pythonExe"))
	if p '= "", ##class(%File).Exists(p) quit p
	// common locations
	for c = "/usr/irissys/bin/irispython", "/usr/bin/irispython" {
		if ##class(%File).Exists(c) quit
	}
	quit $select($get(c)'="" && ##class(%File).Exists(c):c, 1:"irispython")
}

/// Extract text from the file at pPath via the irispython subprocess. Returns the
/// text; sets pError on failure.
ClassMethod FromFile(pPath As %String, Output pError As %String) As %String
{
	set pError = ""
	try {
		set tOut = ##class(%File).TempFilename("txt")
		set tHelper = ..HelperDir()
		// One-liner: add helper dir to path, import, print extracted text (no trailing newline).
		set tPy = "import sys;sys.path.insert(0," _ ..PyStr(tHelper) _ ");import dtl_extract;sys.stdout.write(dtl_extract.extract(" _ ..PyStr(pPath) _ "))"
		set tRC = $ZF(-100, "/STDOUT=""" _ tOut _ """/STDERR=""" _ tOut _ ".err""", ..PythonExe(), "-c", tPy)
		set tText = ..ReadFile(tOut)
		do ##class(%File).Delete(tOut)
		do ##class(%File).Delete(tOut _ ".err")
		if $extract(tText, 1, 17) = "__EXTRACT_ERROR__" {
			set pError = $extract(tText, 18, *)
			return ""
		}
		if (tText = "") && (tRC '= 0) {
			set pError = "extractor subprocess failed (rc=" _ tRC _ ")"
			return ""
		}
		return tText
	} catch ex {
		set pError = ex.DisplayString()
		return ""
	}
}

ClassMethod ReadFile(pPath As %String) As %String
{
	quit:'##class(%File).Exists(pPath) ""
	set s = ##class(%Stream.FileCharacter).%New()
	do s.LinkToFile(pPath)
	set t = ""
	while 's.AtEnd { set t = t _ s.Read(16000) }
	quit t
}

/// Render an ObjectScript string as a Python single-quoted literal.
ClassMethod PyStr(pVal As %String) As %String
{
	quit "'" _ $replace($replace(pVal, "\", "\\"), "'", "\'") _ "'"
}

}
