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

}
