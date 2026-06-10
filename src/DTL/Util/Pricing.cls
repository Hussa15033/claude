/// Per-model token pricing (USD per 1,000,000 tokens) used to cost each LLM call.
/// Prices are a best-effort built-in table keyed by a substring of the model id;
/// unknown models cost 0 (shown as "—" in the UI) rather than guessing. Override
/// or extend at runtime via ^DTL.Config("price", <key>) = "<inUSD/M>,<outUSD/M>".
Class DTL.Util.Pricing Extends %RegisteredObject
{

/// Return {in, out} USD-per-million for a model id (case-insensitive substring
/// match, longest key wins), or {0,0} if unknown.
ClassMethod RatesFor(pModel As %String, Output pIn As %Numeric, Output pOut As %Numeric)
{
	set pIn = 0, pOut = 0
	set m = $zconvert($get(pModel), "L")
	quit:m=""
	// Built-in table: key (substring) -> in,out USD per 1M tokens.
	// OpenAI + Anthropic-on-Bedrock families. Longest matching key wins.
	set t("gpt-4o-mini") = "0.15,0.60"
	set t("gpt-4o") = "2.50,10.00"
	set t("gpt-4.1-mini") = "0.40,1.60"
	set t("gpt-4.1-nano") = "0.10,0.40"
	set t("gpt-4.1") = "2.00,8.00"
	set t("gpt-4-turbo") = "10.00,30.00"
	set t("gpt-3.5") = "0.50,1.50"
	set t("o4-mini") = "1.10,4.40"
	set t("o3-mini") = "1.10,4.40"
	set t("o3") = "2.00,8.00"
	set t("o1-mini") = "1.10,4.40"
	set t("o1") = "15.00,60.00"
	set t("claude-opus-4") = "5.00,25.00"
	set t("claude-sonnet-4") = "3.00,15.00"
	set t("claude-haiku-4") = "1.00,5.00"
	set t("claude-3-5-haiku") = "0.80,4.00"
	set t("claude-3-5-sonnet") = "3.00,15.00"
	set t("claude-3-haiku") = "0.25,1.25"
	set t("claude-3-opus") = "15.00,75.00"
	// runtime overrides take precedence (exact-or-substring against the config key)
	set k = "", best = "", bestLen = 0
	for {
		set k = $order(^DTL.Config("price", k))
		quit:k=""
		if (m [ $zconvert(k, "L")), ($length(k) > bestLen) set best = $get(^DTL.Config("price", k)), bestLen = $length(k)
	}
	if best '= "" { set pIn = +$piece(best, ",", 1), pOut = +$piece(best, ",", 2)  quit }
	// built-in: longest substring key that appears in the model id
	set k = "", best = "", bestLen = 0
	for {
		set k = $order(t(k))
		quit:k=""
		if (m [ k), ($length(k) > bestLen) set best = t(k), bestLen = $length(k)
	}
	if best '= "" set pIn = +$piece(best, ",", 1), pOut = +$piece(best, ",", 2)
}

/// USD cost of one call: (in/1e6)*inRate + (out/1e6)*outRate. 0 if model unknown.
ClassMethod Cost(pModel As %String, pInTokens As %Integer, pOutTokens As %Integer) As %Numeric
{
	do ..RatesFor(pModel, .tIn, .tOut)
	quit (((+pInTokens) / 1000000) * tIn) + (((+pOutTokens) / 1000000) * tOut)
}

}
