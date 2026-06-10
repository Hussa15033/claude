/// Business Service that ingests uploaded SPECIFICATION documents via the
/// EnsLib.File.InboundAdapter. The REST layer writes an upload to the watched
/// specs/ directory named "<token>.<ext>"; this service picks it up, extracts the
/// plain text (pypdf / python-docx / plain) through DTL.Util.DocExtract, and fills
/// the matching DTL.Data.SpecDoc record (Status -> READY). The UI then fetches the
/// text via GET /specs/{token}.
Class DTL.Svc.SpecFileService Extends Ens.BusinessService
{

Parameter ADAPTER = "EnsLib.File.InboundAdapter";

/// Ensure the adapter watches the derived specs/ directory even if the production
/// item setting wasn't persisted. The data dir is recorded by the installer in
/// ^DTL.Config; we set the adapter paths at service init so polling always works.
Method OnInit() As %Status
{
	set tData = $get(^DTL.Config("dataDir"))
	if tData '= "" {
		set tData = ##class(%File).NormalizeDirectory(tData)
		if (..Adapter.FilePath = "") set ..Adapter.FilePath = ##class(%File).NormalizeDirectory(tData _ "specs")
		if (..Adapter.ArchivePath = "") set ..Adapter.ArchivePath = ##class(%File).NormalizeDirectory(tData _ "specsarchive")
	}
	quit $$$OK
}

/// Called by the file adapter for each uploaded spec document.
Method OnProcessInput(pInput As %Stream.Object, Output pOutput As %RegisteredObject, ByRef pHint As %String) As %Status
{
	set tSC = $$$OK
	try {
		// Resolve the work-file path the adapter linked (preferred) or pHint.
		set tPath = ""
		if $isobject(pInput), pInput.%Extends("%Library.FileStreamAdaptor") set tPath = pInput.Filename
		if tPath = "" set tPath = $get(pHint)
		set tBase = ##class(%File).GetFilename(tPath)
		// token = filename without extension (REST names the file <token>.<ext>).
		set tToken = $piece(tBase, ".", 1, $length(tBase, ".") - 1)
		if tToken = "" set tToken = tBase

		$$$LOGINFO("Spec upload received: " _ tBase _ " (token " _ tToken _ ")")

		// Find or create the SpecDoc record.
		set tDoc = ##class(DTL.Data.SpecDoc).OpenByToken(tToken, .sc)
		if '$isobject(tDoc) {
			set tDoc = ##class(DTL.Data.SpecDoc).%New()
			set tDoc.Token = tToken
			set tDoc.CreatedAt = ##class(DTL.Data.Job).Now()
		}
		// Keep the ORIGINAL upload filename (set by /upload); only fall back to the
		// on-disk name if none was recorded, so the saved-spec picker shows real names.
		if tDoc.FileName = "" set tDoc.FileName = tBase

		// Extract text.
		set tText = ##class(DTL.Util.DocExtract).FromFile(tPath, .tErr)
		do tDoc.Text.Clear()
		if tErr '= "" {
			set tDoc.Status = "ERROR", tDoc.Error = tErr
		} else {
			set tDoc.Status = "READY"
			do tDoc.Text.Write(tText)
		}
		set tSC = tDoc.%Save()
		$$$LOGINFO("Spec '" _ tToken _ "' -> " _ tDoc.Status _ " (" _ tDoc.Text.Size _ " chars)")
	} catch ex {
		set tSC = ex.AsStatus()
	}
	quit tSC
}

}
