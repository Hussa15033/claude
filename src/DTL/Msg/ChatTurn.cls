/// One turn in the LLM chat transcript (system / user / assistant).
/// Serial (embedded) so it does not create its own extent when stored inside a
/// persistent Ens.Request — see <class>DTL.Msg.LLMRequest</class>.
Class DTL.Msg.ChatTurn Extends (%SerialObject, %XML.Adaptor)
{

/// Chat role: system, user, or assistant.
Property Role As %String(VALUELIST = ",system,user,assistant") [ Required ];

/// Message content. HL7 + DTL turns stay well under the long-string ceiling,
/// so a long %String is simpler and safer here than a stream.
Property Content As %String(MAXLEN = 1000000);

/// Token usage + cost for the LLM CALL that produced this turn. Only meaningful on
/// "assistant" turns (the reply): InputTokens covers the whole prompt sent for this
/// call, OutputTokens the reply, Cost the USD for this single request.
Property InputTokens As %Integer [ InitialExpression = 0 ];

Property OutputTokens As %Integer [ InitialExpression = 0 ];

Property Cost As %Numeric(SCALE = 6) [ InitialExpression = 0 ];

/// Marks this turn as the END of the cacheable static prefix. The first system
/// turn (which carries the big, unchanging DTL element schema + HL7 schema + the
/// structured spec) is flagged so the LLMConnector can attach a provider prompt-
/// cache breakpoint (Anthropic cache_control) up to and including it — every
/// subsequent repair/feedback turn then re-reads that prefix from cache instead of
/// re-billing it at full input price.
Property CacheBreakpoint As %Boolean [ InitialExpression = 0 ];

/// Auxiliary turn: a side LLM call (e.g. the spec-conformance judge) that is shown
/// in the UI transcript for transparency but is NOT part of the build conversation,
/// so FillTranscript skips it (it must not be re-sent to the build model as if the
/// model had said it).
Property Aux As %Boolean [ InitialExpression = 0 ];

}
