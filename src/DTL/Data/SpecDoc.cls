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

/// Extraction confidence 0..1 (how faithfully the markdown represents the source;
/// see dtl_extract.py). Low confidence (scanned PDF, dropped tables, mojibake)
/// means the UI MUST route this spec through human review before it's used.
Property Confidence As %Numeric [ InitialExpression = 1 ];

/// JSON metadata from extraction: {confidence, pages, chars, tables, emptyPages,
/// method, warnings:[...]} — surfaced in the UI so the human knows what to check.
Property ExtractMeta As %String(MAXLEN = 4000);

/// CONCISE specification (markdown), generated from Text at upload time: a clear,
/// de-noised restatement of the transformation rules GROUPED BY message/segment
/// type, each item carrying a reference back to the original. This is what the user
/// reviews/edits/approves and what every downstream step (plan, generate, judge)
/// is grounded on — so re-selecting a saved spec loads THIS, not the raw text.
/// Held as a stream (can be large for a multi-message interface spec).
Property ConciseSpec As %Stream.GlobalCharacter;

/// Provenance for the concise spec (JSON): the structured groups + items with the
/// verbatim source snippet each item came from, for the side-by-side click-to-
/// reference review. Shape: {groups:[{type,label,items:[{id,rule,sourceQuote,
/// inferred}]}], ambiguities:[...], coverage:{...}}.
Property ConciseProvenance As %Stream.GlobalCharacter;

/// PENDING | READY | ERROR for the CONCISE-spec generation step (independent of the
/// text-extraction Status above; the concise spec is generated after extraction).
Property ConciseStatus As %String(VALUELIST = ",PENDING,READY,ERROR") [ InitialExpression = "PENDING" ];

/// Has the human reviewed + APPROVED the concise spec? Only an approved concise
/// spec should drive generation without re-review.
Property ConciseApproved As %Boolean [ InitialExpression = 0 ];

/// LLM verification verdict (JSON) of the concise spec vs the original: completeness
/// + hallucination check {complete, faithful, score, missing:[...], hallucinated:[...]}.
Property ConciseVerdict As %String(MAXLEN = 8000);

/// Error detail for a FAILED concise-spec generation (e.g. bad API key, rate limit),
/// kept separate from the extraction Error so a good extraction with a failed concise
/// pass surfaces the right message to the user.
Property ConciseError As %String(MAXLEN = 2000);

Property CreatedAt As %String(MAXLEN = 32);

/// Read the concise-spec stream into a string (for the REST/JSON layer).
Method ConciseStr() As %String
{
	quit ##class(DTL.Data.Job).StreamStr(..ConciseSpec)
}

/// Read the concise-provenance stream into a string.
Method ConciseProvStr() As %String
{
	quit ##class(DTL.Data.Job).StreamStr(..ConciseProvenance)
}

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
<Value name="8"><Value>Confidence</Value></Value>
<Value name="9"><Value>ExtractMeta</Value></Value>
<Value name="10"><Value>ConciseSpec</Value></Value>
<Value name="11"><Value>ConciseProvenance</Value></Value>
<Value name="12"><Value>ConciseStatus</Value></Value>
<Value name="13"><Value>ConciseApproved</Value></Value>
<Value name="14"><Value>ConciseVerdict</Value></Value>
<Value name="15"><Value>ConciseError</Value></Value>
</Data>
<DataLocation>^DTL.Data.SpecDocD</DataLocation>
<DefaultData>SpecDocDefaultData</DefaultData>
<IdLocation>^DTL.Data.SpecDocD</IdLocation>
<IndexLocation>^DTL.Data.SpecDocI</IndexLocation>
<StreamLocation>^DTL.Data.SpecDocS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
