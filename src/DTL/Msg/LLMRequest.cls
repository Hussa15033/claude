/// Request sent from <class>DTL.Proc.Orchestrator</class> to
/// <class>DTL.Op.LLMConnector</class> for one chat-completion call. Carries the
/// full accumulating transcript so the business operation stays stateless and
/// every turn is visible in the Visual Trace.
Class DTL.Msg.LLMRequest Extends Ens.Request
{

Property JobId As %String(MAXLEN = 64);

/// 1-based attempt number this call corresponds to.
Property Attempt As %Integer;

/// Provider for this call: "openai" or "mock". Blank = operation's Mode default.
Property Provider As %String(MAXLEN = 16);

/// Model id; blank means use the business operation's configured default.
Property Model As %String(MAXLEN = 128);

/// Per-call API key (from the user). Blank = use the operation's configured
/// credentials. Transient: not persisted to the Job record.
Property ApiKey As %String(MAXLEN = 512);

/// Sampling temperature (0 = deterministic, best for code generation).
Property Temperature As %Numeric [ InitialExpression = 0 ];

/// Max tokens for the completion.
Property MaxTokens As %Integer [ InitialExpression = 4096 ];

/// Full conversation so far: [system, user1, assistant1, user2, ...].
Property Transcript As list Of DTL.Msg.ChatTurn;

}
