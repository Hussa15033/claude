/// Persistent record of an uploaded specification document and the plain text
/// extracted from it. The REST layer writes the upload to a watched directory
/// keyed by Token; DTL.Svc.SpecFileService picks it up, extracts the text, and
/// fills Text + sets Status=READY. The UI polls GET /specs/{token} for the text.
Class DTL.Data.SpecDoc Extends (%Persistent, %JSON.Adaptor)
{

/// Opaque token tying the upload, the on-disk file, and this record together.
Property Token As %String(MAXLEN = 64) [ Required ];

Index TokenIdx On Token [ Unique ];

/// Original filename as uploaded (for display + extension-based extraction).
Property FileName As %String(MAXLEN = 512);

/// PENDING (written, not yet extracted) | READY | ERROR.
Property Status As %String(VALUELIST = ",PENDING,READY,ERROR") [ InitialExpression = "PENDING" ];

/// Extracted specification, converted to Markdown. Held as a STREAM: a large
/// document (e.g. a 46-page HL7 spec) easily exceeds any %String MAXLEN and would
/// raise "<value> length longer than MAXLEN allowed".
Property Text As %Stream.GlobalCharacter;

/// Error detail if extraction failed.
Property Error As %String(MAXLEN = 2000);

Property CreatedAt As %String(MAXLEN = 32);

ClassMethod OpenByToken(pToken As %String, Output pSC As %Status) As DTL.Data.SpecDoc
{
	set pSC = $$$OK
	quit ..TokenIdxOpen(pToken, , .pSC)
}

/// Read the extracted text stream into a string (for the REST/JSON layer).
Method TextStr() As %String
{
	quit ##class(DTL.Data.Job).StreamStr(..Text)
}

Storage Default
{
<Data name="SpecDocDefaultData">
<Value name="1"><Value>%%CLASSNAME</Value></Value>
<Value name="2"><Value>Token</Value></Value>
<Value name="3"><Value>FileName</Value></Value>
<Value name="4"><Value>Status</Value></Value>
<Value name="5"><Value>Text</Value></Value>
<Value name="6"><Value>Error</Value></Value>
<Value name="7"><Value>CreatedAt</Value></Value>
</Data>
<DataLocation>^DTL.Data.SpecDocD</DataLocation>
<DefaultData>SpecDocDefaultData</DefaultData>
<IdLocation>^DTL.Data.SpecDocD</IdLocation>
<IndexLocation>^DTL.Data.SpecDocI</IndexLocation>
<StreamLocation>^DTL.Data.SpecDocS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
