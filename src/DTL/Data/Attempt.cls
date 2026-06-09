/// One attempt within a DTL-generation job, recorded live by the orchestrator
/// so the UI can show attempt-by-attempt progress. Serial (embedded in Job).
Class DTL.Data.Attempt Extends (%SerialObject, %JSON.Adaptor)
{

/// 1-based attempt number.
Property Number As %Integer;

/// What happened: GENERATING | COMPILE_FAIL | RUNTIME_FAIL | MISMATCH | SUCCESS | LLM_ERROR.
Property Phase As %String(MAXLEN = 32);

Property Compiled As %Boolean [ InitialExpression = 0 ];

Property Ran As %Boolean [ InitialExpression = 0 ];

Property Matched As %Boolean [ InitialExpression = 0 ];

Property Score As %Numeric [ InitialExpression = 0 ];

/// Short human-readable note (compile error head, diff count, etc.).
Property Message As %String(MAXLEN = 4000);

Method ToDynamic() As %DynamicObject
{
	set o = {}
	set o.number = ..Number
	set o.phase = ..Phase
	set o.compiled = ..Compiled
	set o.ran = ..Ran
	set o.matched = ..Matched
	set o.score = ..Score
	set o.message = ..Message
	quit o
}

}
