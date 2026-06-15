/// Request to (re)generate or audit the CONCISE specification for an uploaded
/// document, dispatched ASYNCHRONOUSLY onto the production's durable queue and
/// handled by <class>DTL.Proc.SpecForge</class>.
///
/// WHY a queued message instead of a detached JOB: the work is a long, slow LLM
/// call. A detached `job` process is unsupervised — if it is killed (slow/large
/// Bedrock reply, CSP worker recycle, container blip) the SpecDoc strands at
/// PENDING forever and the produced reply is orphaned (an LLMResponse carries no
/// token, so nothing can re-correlate it). A persisted Ens.Request on the BP queue
/// is durable: a worker always processes it and writes a terminal READY/ERROR, and
/// if a worker dies mid-flight Ensemble REDELIVERS it on recovery. So the record
/// can never hang in PENDING.
///
/// The per-user API key travels ON this message (same established pattern as
/// <class>DTL.Msg.LLMRequest</class>) — it is never written to the SpecDoc record
/// and is purged with normal Ens message purging.
Class DTL.Msg.ConciseRequest Extends Ens.Request
{

/// Upload token identifying the DTL.Data.SpecDoc to act on.
Property Token As %String(MAXLEN = 64);

/// LLM provider for the call: "openai" | "bedrock" | "mock".
Property Provider As %String(MAXLEN = 16);

/// Model id (the dedicated concise-spec model when the UI supplies one).
Property Model As %String(MAXLEN = 128);

/// Per-user API key (transient; not persisted on the SpecDoc).
Property ApiKey As %String(MAXLEN = 512);

/// AWS region for the Bedrock provider; ignored for openai/mock.
Property Region As %String(MAXLEN = 32);

/// "generate" = (re)generate the concise spec then run the audit;
/// "verify"   = re-run only the completeness/faithfulness audit.
Property Mode As %String(VALUELIST = ",generate,verify") [ InitialExpression = "generate" ];

}
