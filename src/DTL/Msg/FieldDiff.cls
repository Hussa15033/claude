/// A single field-level difference between the DTL's actual output and the
/// expected output, produced by <class>DTL.Util.Verifier</class>. Serial so it
/// embeds inside <class>DTL.Msg.ForgeResponse</class> without its own extent.
Class DTL.Msg.FieldDiff Extends (%SerialObject, %XML.Adaptor)
{

/// HL7 path of the differing field, e.g. "PID:8" or "PID:5(1).1.1".
Property Path As %String(MAXLEN = 128);

/// Segment name for human readability, e.g. "PID".
Property SegName As %String(MAXLEN = 16);

/// Nature of the difference.
Property Kind As %String(VALUELIST = ",MISSING,EXTRA,VALUE_MISMATCH") [ InitialExpression = "VALUE_MISMATCH" ];

/// Value found in the expected (target) message.
Property ExpectedValue As %String(MAXLEN = 4096);

/// Value produced by the candidate DTL.
Property ActualValue As %String(MAXLEN = 4096);

/// HIGH = structurally important / clearly derivable from source;
/// LOW = expected value not present anywhere in source, likely illustrative
/// (do not hard-code — honours the "output may not be a literal transform" caveat).
Property Severity As %String(VALUELIST = ",HIGH,MED,LOW") [ InitialExpression = "MED" ];

/// Optional hint fed back to the LLM.
Property Hint As %String(MAXLEN = 512);

}
