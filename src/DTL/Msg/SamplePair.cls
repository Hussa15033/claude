/// One input/output HL7v2 example pair, used as a teaching example for the LLM.
/// Serial so a ForgeRequest can carry a list of them without extent pollution.
Class DTL.Msg.SamplePair Extends (%SerialObject, %XML.Adaptor)
{

/// Raw input HL7v2 message (CR- or LF-delimited).
Property InputHL7 As %String(MAXLEN = 1000000);

/// Raw expected output HL7v2 message.
Property OutputHL7 As %String(MAXLEN = 1000000);

/// Derived source DocType "version:structure" (filled in by the service/REST layer).
Property SourceDocType As %String(MAXLEN = 64);

/// Derived target DocType.
Property TargetDocType As %String(MAXLEN = 64);

}
