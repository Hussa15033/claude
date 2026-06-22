/// One LLM call's cost, recorded the moment the call returns — the SINGLE SOURCE OF
/// TRUTH for every cost figure shown anywhere in the product. Per-spec subtotals,
/// per-DTL subtotals, the project timeline, the project total and the account grand
/// total are ALL computed by summing rows of this ledger, so they can never disagree.
///
/// Before this ledger existed, DTL-job costs were summed from the job transcript while
/// spec-generation / spec-verification costs were thrown away entirely (SpecConcise
/// discarded the token usage), so the "all jobs" grand total silently undercounted by
/// every specification ever generated. Routing EVERY call through DTL.Util.Cost.Record
/// fixes that: one row per call, one formula (DTL.Util.Pricing.Cost) for the dollar
/// amount, one place that bumps the grand total.
///
/// A row is tagged by what it was for:
///   Category — spec.generate | spec.verify | dtl.plan | dtl.generate | dtl.judge
///   RefKind  — "spec" (RefId = SpecDoc.Token) | "dtl" (RefId = Job.JobId)
/// A project rolls up by enumerating its spec tokens + job ids and summing the rows
/// whose RefId matches — so no project token needs to be denormalised onto the row.
Class DTL.Data.CostEntry Extends %Persistent
{

/// Monotonic sequence number (from $increment(^DTL.CostSeq)) — gives a stable,
/// gap-tolerant chronological order for the timeline even when timestamps collide.
Property Seq As %Integer;

Index SeqIdx On Seq [ Unique ];

/// Wall-clock time the call settled ($zdatetime($ztimestamp,3,1) — UTC, sortable).
Property Ts As %String(MAXLEN = 32);

/// What the call was for. See class header for the controlled vocabulary.
Property Category As %String(VALUELIST = ",spec.generate,spec.verify,dtl.plan,dtl.generate,dtl.judge,other") [ InitialExpression = "other" ];

/// "spec" or "dtl" — tells you how to read RefId.
Property RefKind As %String(MAXLEN = 8);

/// The owning entity's id: a SpecDoc.Token (RefKind="spec") or Job.JobId (RefKind="dtl").
Property RefId As %String(MAXLEN = 64);

Index RefIdx On RefId;

/// Human-facing one-line description for the timeline, e.g.
/// "Generation of specification orders.pdf" or "Judging of DTL ADT_A01".
Property Label As %String(MAXLEN = 256);

/// The model id the call used (so an unknown-priced model is visible as such).
Property Model As %String(MAXLEN = 128);

Property InTok As %Integer [ InitialExpression = 0 ];

Property OutTok As %Integer [ InitialExpression = 0 ];

/// USD for THIS call. Always DTL.Util.Pricing.Cost(Model, InTok, OutTok) — computed
/// once, at record time, from the tokens; never passed in pre-rounded.
Property Cost As %Numeric(SCALE = 6) [ InitialExpression = 0 ];

Storage Default
{
<Data name="CostEntryDefaultData">
<Value name="1">
<Value>%%CLASSNAME</Value>
</Value>
<Value name="2">
<Value>Seq</Value>
</Value>
<Value name="3">
<Value>Ts</Value>
</Value>
<Value name="4">
<Value>Category</Value>
</Value>
<Value name="5">
<Value>RefKind</Value>
</Value>
<Value name="6">
<Value>RefId</Value>
</Value>
<Value name="7">
<Value>Label</Value>
</Value>
<Value name="8">
<Value>Model</Value>
</Value>
<Value name="9">
<Value>InTok</Value>
</Value>
<Value name="10">
<Value>OutTok</Value>
</Value>
<Value name="11">
<Value>Cost</Value>
</Value>
</Data>
<DataLocation>^DTL.Data.CostEntryD</DataLocation>
<DefaultData>CostEntryDefaultData</DefaultData>
<IdLocation>^DTL.Data.CostEntryD</IdLocation>
<IndexLocation>^DTL.Data.CostEntryI</IndexLocation>
<StreamLocation>^DTL.Data.CostEntryS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
