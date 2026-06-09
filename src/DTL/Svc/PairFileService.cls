/// Business Service that ingests HL7v2 example pairs and starts a DTL forge job.
///
/// It watches an input directory (via EnsLib.File.InboundAdapter). For each input
/// file that arrives it locates the matching output file (same basename) in a
/// configured outputs directory, derives the source/target DocTypes from the two
/// messages, and dispatches a <class>DTL.Msg.ForgeRequest</class> to the
/// orchestration business process.
///
/// Input and output of a pair share the same filename, e.g.
///   inputs/ADT_A01_Admit.hl7  +  outputs/ADT_A01_Admit.hl7
Class DTL.Svc.PairFileService Extends Ens.BusinessService
{

Parameter ADAPTER = "EnsLib.File.InboundAdapter";

/// Directory holding the expected OUTPUT messages (matching basenames).
Property OutputsPath As %String(MAXLEN = 1024);

/// Target config item (the orchestrator BP).
Property TargetConfigName As %String [ InitialExpression = "DTL.Proc.Orchestrator" ];

/// Max generate/compile/verify attempts per job.
Property MaxAttempts As %Integer [ InitialExpression = 5 ];

/// Success policy passed through to the orchestrator.
Property SuccessPolicy As %String(VALUELIST = ",CompileOnly,CompileRun,CompileMatch,CompileMatchTolerance") [ InitialExpression = "CompileMatch" ];

/// Match threshold for CompileMatchTolerance.
Property MatchThreshold As %Numeric [ InitialExpression = 0.85 ];

/// Optional operator instructions appended to every job.
Property Instructions As %String(MAXLEN = 8000);

Parameter SETTINGS = "OutputsPath:Basic,TargetConfigName:Basic,MaxAttempts:Basic,SuccessPolicy:Basic,MatchThreshold:Basic,Instructions:Basic";

/// Safety net: derive the watched inputs/ + outputs/ + archive/ paths from the
/// installer-recorded data dir if the item settings weren't persisted, so the
/// service always polls the right place.
Method OnInit() As %Status
{
	set tData = $get(^DTL.Config("dataDir"))
	if tData '= "" {
		set tData = ##class(%File).NormalizeDirectory(tData)
		if (..Adapter.FilePath = "") set ..Adapter.FilePath = ##class(%File).NormalizeDirectory(tData _ "inputs")
		if (..Adapter.ArchivePath = "") set ..Adapter.ArchivePath = ##class(%File).NormalizeDirectory(tData _ "archive")
		if (..OutputsPath = "") set ..OutputsPath = ##class(%File).NormalizeDirectory(tData _ "outputs")
	}
	quit $$$OK
}

/// Called by the file adapter for each input file. The EnsLib.File.InboundAdapter
/// passes the source filename through the pHint argument (by reference).
Method OnProcessInput(pInput As %Stream.Object, Output pOutput As %RegisteredObject, ByRef pHint As %String) As %Status
{
	set tSC = $$$OK
	try {
		// Resolve the basename of the file just read. The File InboundAdapter
		// passes a %FileCharacterStream whose .Filename is the (work) file path;
		// pHint is used as a fallback for adapters that supply it that way.
		set tFullName = ""
		if $isobject(pInput), pInput.%Extends("%Library.FileStreamAdaptor") {
			set tFullName = pInput.Filename
		}
		if tFullName = "" set tFullName = $get(pHint)
		set tBase = ##class(%File).GetFilename(tFullName)
		if tBase = "" set tBase = tFullName
		// Strip any archive timestamp suffix like name.hl7_2026-06-08_11.33...
		if tBase [ ".hl7_" set tBase = $piece(tBase, "_", 1)
		set tName = $piece(tBase, ".", 1, $length(tBase, ".") - 1)
		if tName = "" set tName = tBase

		// Read the input message.
		set tSrcHL7 = ..ReadStream(pInput)

		// Locate and read the matching expected output.
		set tOutFile = ..FindMatchingOutput(tBase)
		if tOutFile = "" {
			$$$LOGWARNING("No matching output file for input '"_tBase_"' in "_..OutputsPath_"; skipping.")
			quit
		}
		set tTgtHL7 = ..ReadFile(tOutFile)

		// Derive DocTypes from each message (structure, not trigger event).
		set tSrcDoc = ##class(DTL.Util.HL7).DeriveDocType(tSrcHL7, .sv, .ss)
		set tTgtDoc = ##class(DTL.Util.HL7).DeriveDocType(tTgtHL7, .tv, .ts)

		// Build and dispatch the forge request.
		set tReq = ##class(DTL.Msg.ForgeRequest).%New()
		set tReq.JobId = $zhex($random(2147483647))
		set tReq.InputName = tName
		do tReq.SourceHL7.Write(tSrcHL7)
		do tReq.TargetHL7.Write(tTgtHL7)
		set tReq.SourceDocType = tSrcDoc
		set tReq.TargetDocType = tTgtDoc
		set tReq.Instructions = ..Instructions
		set tReq.MaxAttempts = ..MaxAttempts
		set tReq.SuccessPolicy = ..SuccessPolicy
		set tReq.MatchThreshold = ..MatchThreshold

		$$$LOGINFO("Forge job "_tReq.JobId_" for '"_tName_"' ("_tSrcDoc_" -> "_tTgtDoc_")")
		set tSC = ..SendRequestAsync(..TargetConfigName, tReq)
	} catch ex {
		set tSC = ex.AsStatus()
	}
	quit tSC
}

/// Find the output file matching the given input basename.
Method FindMatchingOutput(pBase As %String) As %String
{
	quit:..OutputsPath="" ""
	set tDir = ..OutputsPath
	if $extract(tDir, *) '= "/" set tDir = tDir _ "/"
	set tCandidate = tDir _ pBase
	if ##class(%File).Exists(tCandidate) quit tCandidate
	// Try matching by stem ignoring extension.
	set tStem = $piece(pBase, ".", 1, $length(pBase, ".") - 1)
	set rs = ##class(%ResultSet).%New("%File:FileSet")
	do rs.Execute(..OutputsPath, tStem _ ".*")
	while rs.Next() {
		quit:rs.GetData(1)'=""
	}
	if $isobject(rs), rs.GetData(1) '= "" quit rs.GetData(1)
	quit ""
}

ClassMethod ReadStream(pStream As %Stream.Object) As %String
{
	quit:'$isobject(pStream) ""
	do pStream.Rewind()
	set s = ""
	while 'pStream.AtEnd { set s = s _ pStream.Read(16000) }
	quit s
}

ClassMethod ReadFile(pPath As %String) As %String
{
	set f = ##class(%Stream.FileCharacter).%New()
	do f.LinkToFile(pPath)
	quit f.Read(3600000)
}

}
