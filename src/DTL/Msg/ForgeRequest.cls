/// Request that drives one DTL-generation job: a single input/output HL7v2
/// example pair plus the policy controlling the regeneration loop. Emitted by
/// <class>DTL.Svc.PairFileService</class> and consumed by
/// <class>DTL.Proc.Orchestrator</class>.
Class DTL.Msg.ForgeRequest Extends Ens.Request
{

/// Correlation id for this job (also used to name throwaway candidate classes).
Property JobId As %String(MAXLEN = 64);

/// Shared basename of the input/output pair, e.g. "ADT_A01_Admit".
Property InputName As %String(MAXLEN = 256);

/// Natural-language description of the input message / desired transformation,
/// supplied by the user. Injected into the LLM prompt as the spec. Held as a
/// stream so a document-derived spec can exceed the 32 000-char %String cap.
Property InputSpec As %Stream.GlobalCharacter;

/// Additional sample input/output pairs (beyond Source/TargetHL7 below) used as
/// teaching examples. When present, ALL pairs are shown to the LLM; the DTL is
/// verified against the primary pair (Source/TargetHL7) for an objective gate.
Property SamplePairs As list Of DTL.Msg.SamplePair;

/// Raw input HL7v2 message (segments may be CR- or LF-delimited).
Property SourceHL7 As %Stream.GlobalCharacter;

/// Raw expected output HL7v2 message.
Property TargetHL7 As %Stream.GlobalCharacter;

/// Source DocType "version:structure", e.g. "2.3:ADT_A01". Derived by the
/// service from MSH-9/MSH-12 via the HL7 schema (structure, not trigger event).
Property SourceDocType As %String(MAXLEN = 64);

/// Target DocType, e.g. "2.5:ADT_A01".
Property TargetDocType As %String(MAXLEN = 64);

/// Optional free-text operator intent describing the transformation rules.
Property Instructions As %String(MAXLEN = 8000);

/// LLM provider chosen by the user: "openai" or "mock". Blank = operation default.
Property Provider As %String(MAXLEN = 16);

/// LLM model id chosen by the user (e.g. "gpt-4o"). Blank = the operation's
/// configured default model.
Property Model As %String(MAXLEN = 128);

/// API key supplied by the user for this job. Transient — passed to the LLM
/// operation per-call and NEVER persisted to the Job record or logs. Blank =
/// fall back to the operation's configured credentials.
Property ApiKey As %String(MAXLEN = 512);

/// Maximum number of generate/compile/verify attempts before giving up.
Property MaxAttempts As %Integer [ InitialExpression = 5 ];

/// Success policy:
///   CompileOnly             - accept as soon as the DTL compiles
///   CompileRun (default)    - accept when it compiles AND runs (objective gates;
///                             score is reported but not gating — honours the caveat)
///   CompileMatch            - accept only on exact normalized match
///   CompileMatchTolerance   - accept when it compiles, runs, and score >= MatchThreshold
Property SuccessPolicy As %String(VALUELIST = ",CompileOnly,CompileRun,CompileMatch,CompileMatchTolerance") [ InitialExpression = "CompileMatch" ];

/// Match-score threshold (0..1) used by CompileMatchTolerance.
Property MatchThreshold As %Numeric(MAXVAL = 1, MINVAL = 0) [ InitialExpression = 0.85 ];

}
