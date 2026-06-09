/// Result of a DTL-generation job returned by <class>DTL.Proc.Orchestrator</class>.
/// Always carries the best compiling+running candidate found, even on failure,
/// together with its diff against the expected output.
Class DTL.Msg.ForgeResponse Extends Ens.Response
{

Property JobId As %String(MAXLEN = 64);

/// True if the job satisfied its success policy.
Property Success As %Boolean [ InitialExpression = 0 ];

/// Outcome classification.
Property Verdict As %String(VALUELIST = ",SUCCESS,FAIL_COMPILE,FAIL_RUNTIME,FAIL_MATCH,UNSATISFIABLE,LLM_ERROR") ;

/// Name of the final compiled DTL class (the promoted winner, if any).
Property GeneratedClassName As %String(MAXLEN = 220);

/// How many attempts were consumed.
Property AttemptsUsed As %Integer [ InitialExpression = 0 ];

/// Best match score achieved (0..1), reported regardless of policy.
Property FinalScore As %Numeric [ InitialExpression = 0 ];

/// Final (best) DTL class source.
Property FinalDTL As %Stream.GlobalCharacter;

/// transform(input) produced by the chosen DTL.
Property TransformedHL7 As %Stream.GlobalCharacter;

/// Human-readable field diff summary.
Property DiffSummary As %Stream.GlobalCharacter;

/// Last error encountered (compile or runtime), if any.
Property LastError As %String(MAXLEN = 4000);

}
