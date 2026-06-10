/// Response from <class>DTL.Op.LLMConnector</class> — a PURE API connector. It
/// carries the assistant's RAW reply plus transport metadata only. It does NOT
/// extract or validate a DTL class (or anything else) from the payload; the caller
/// (business process / service) is responsible for all content processing.
Class DTL.Msg.LLMResponse Extends Ens.Response
{

Property JobId As %String(MAXLEN = 64);

Property Attempt As %Integer;

/// True when the HTTP call returned 2xx AND the model produced non-empty content.
/// It does NOT imply the content is a valid DTL class — that's the caller's call.
Property Ok As %Boolean [ InitialExpression = 0 ];

Property HttpStatus As %Integer;

/// Full assistant message content — the ONLY payload field. The caller extracts a
/// DTL class / parses JSON / etc. from this.
Property RawContent As %Stream.GlobalCharacter;

/// stop | length | content_filter | ...
Property FinishReason As %String(MAXLEN = 32);

/// Populated on transport / parse / HTTP error.
Property ErrorText As %String(MAXLEN = 2000);

/// Token usage if the provider reported it.
Property TotalTokens As %Integer [ InitialExpression = 0 ];

/// Prompt (input) tokens, if the provider reported them.
Property InputTokens As %Integer [ InitialExpression = 0 ];

/// Completion (output) tokens, if the provider reported them.
Property OutputTokens As %Integer [ InitialExpression = 0 ];

}
