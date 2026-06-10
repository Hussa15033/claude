/// Response from <class>DTL.Op.LLMConnector</class> carrying the assistant's
/// reply and the DTL class extracted from it (markdown fences stripped).
Class DTL.Msg.LLMResponse Extends Ens.Response
{

Property JobId As %String(MAXLEN = 64);

Property Attempt As %Integer;

/// True when the HTTP call returned 2xx and a class definition was extracted.
Property Ok As %Boolean [ InitialExpression = 0 ];

Property HttpStatus As %Integer;

/// Fence-stripped class source, ready for $system.OBJ.LoadStream.
Property ExtractedClass As %Stream.GlobalCharacter;

/// Class name parsed from "Class X Extends ...".
Property ClassName As %String(MAXLEN = 220);

/// Full assistant message content (for debugging / trace).
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
