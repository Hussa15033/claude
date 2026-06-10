/// The interoperability production wiring the DTL GenAI framework:
///   PairFileService (file intake) -> Orchestrator (regeneration loop) -> LLMConnector (HTTP to LLM)
///
/// Defaults target the local mock LLM (mock/mock_llm.py on localhost:8085) so the
/// whole loop runs offline with no API key. To use the real OpenAI API, set the
/// LLMConnector Mode to "openai", configure an SSLConfig + ApiKeyCredentials, and
/// point HTTPServer at api.openai.com:443.
///
/// NOTE: the filesystem paths (FilePath/ArchivePath/OutputsPath/ArtifactDir) are
/// intentionally left blank here -- they are NOT hardcoded. DTL.Setup.Installer
/// derives them from the IRIS manager directory at install time and applies them
/// via Ens.Director.SetItemSettingValue, so the framework is portable across
/// hosts/containers without editing this class.
Class DTL.Setup.Production Extends Ens.Production
{

XData ProductionDefinition
{
<Production Name="DTL.Setup.Production" LogGeneralTraceEvents="false">
  <Description>GenAI-driven HL7 DTL auto-generation framework</Description>
  <ActorPoolSize>2</ActorPoolSize>

  <Item Name="DTL.Svc.PairFileService" Category="DTL" ClassName="DTL.Svc.PairFileService" PoolSize="1" Enabled="true" Foreground="false" InactivityTimeout="0" Comment="" LogTraceEvents="false" Schedule="">
    <Setting Target="Adapter" Name="FilePath"></Setting>
    <Setting Target="Adapter" Name="ArchivePath"></Setting>
    <Setting Target="Adapter" Name="FileSpec">*.hl7</Setting>
    <Setting Target="Adapter" Name="ConfirmComplete">1</Setting>
    <Setting Target="Host" Name="OutputsPath"></Setting>
    <Setting Target="Host" Name="TargetConfigName">DTL.Proc.Orchestrator</Setting>
    <Setting Target="Host" Name="MaxAttempts">5</Setting>
    <Setting Target="Host" Name="SuccessPolicy">CompileMatch</Setting>
  </Item>

  <Item Name="DTL.Proc.Orchestrator" Category="DTL" ClassName="DTL.Proc.Orchestrator" PoolSize="1" Enabled="true" Foreground="false" InactivityTimeout="0" Comment="" LogTraceEvents="false" Schedule="">
    <Setting Target="Host" Name="LLMTarget">DTL.Op.LLMConnector</Setting>
    <Setting Target="Host" Name="LLMTimeout">600</Setting>
    <Setting Target="Host" Name="ArtifactDir"></Setting>
  </Item>

  <Item Name="DTL.Op.LLMConnector" Category="DTL" ClassName="DTL.Op.LLMConnector" PoolSize="1" Enabled="true" Foreground="false" InactivityTimeout="0" Comment="" LogTraceEvents="false" Schedule="">
    <Setting Target="Host" Name="Mode">openai</Setting>
    <Setting Target="Host" Name="ChatPath">/v1/chat/completions</Setting>
    <Setting Target="Host" Name="Model">gpt-4o</Setting>
    <Setting Target="Host" Name="OpenAIHost">api.openai.com</Setting>
    <Setting Target="Host" Name="OpenAIPort">443</Setting>
    <Setting Target="Host" Name="OpenAISSLConfig">DTLOpenAISSL</Setting>
    <Setting Target="Host" Name="MockHost">localhost</Setting>
    <Setting Target="Host" Name="MockPort">8085</Setting>
    <!-- FailureTimeout: how long the operation keeps retrying before failing the
         request. LLM calls (esp. reasoning models like gpt-5.x) can take minutes,
         so raise it well above the 15s default. ResponseTimeout is the per-HTTP
         read wait — raise it to match so a slow completion isn't cut off. -->
    <Setting Target="Host" Name="FailureTimeout">600</Setting>
    <Setting Target="Adapter" Name="ResponseTimeout">300</Setting>
    <Setting Target="Adapter" Name="HTTPServer">api.openai.com</Setting>
    <Setting Target="Adapter" Name="HTTPPort">443</Setting>
    <Setting Target="Adapter" Name="SSLConfig">DTLOpenAISSL</Setting>
  </Item>

  <Item Name="DTL.Svc.SpecFileService" Category="DTL" ClassName="DTL.Svc.SpecFileService" PoolSize="1" Enabled="true" Foreground="false" InactivityTimeout="0" Comment="Ingest uploaded spec documents (pdf/docx/txt) and extract text" LogTraceEvents="false" Schedule="">
    <Setting Target="Adapter" Name="FilePath"></Setting>
    <Setting Target="Adapter" Name="ArchivePath"></Setting>
    <Setting Target="Adapter" Name="FileSpec">*</Setting>
    <Setting Target="Adapter" Name="ConfirmComplete">1</Setting>
  </Item>

  <Item Name="EnsLib.Testing.Service" Category="DTL" ClassName="EnsLib.Testing.Service" PoolSize="1" Enabled="true" Foreground="false" InactivityTimeout="0" Comment="Inject ForgeRequests for testing/demo" LogTraceEvents="false" Schedule="">
  </Item>

</Production>
}

}
