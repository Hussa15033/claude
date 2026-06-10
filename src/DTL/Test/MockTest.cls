/// Validates that the mock LLM's scripted curriculum (broken -> wrong -> correct)
/// actually behaves as intended when its output is run through the real
/// Extractor + Verifier. Run after starting the mock on localhost:8085:
///   do ##class(DTL.Test.MockTest).RunAll()
Class DTL.Test.MockTest Extends %RegisteredObject
{

ClassMethod ReadFile(path As %String) As %String
{
	set s = ##class(%Stream.FileCharacter).%New()
	do s.LinkToFile(path)
	quit s.Read(1000000)
}

/// Call the mock with a given number of prior assistant turns; return content.
ClassMethod CallMock(pUserText As %String, pPrior As %Integer, pPort As %Integer = 8085) As %String
{
	set arr = []
	do arr.%Push({"role": "system", "content": "sys"})
	do arr.%Push({"role": "user", "content": (pUserText)})
	// Prior attempts are DTL replies — they MUST look like a DTL (contain
	// <transform>) so the mock's build-curriculum counter recognises them as
	// generation attempts (it skips structuring-JSON and judge turns).
	for i = 1:1:pPrior {
		do arr.%Push({"role": "assistant", "content": "<transform>prev attempt</transform>"})
		do arr.%Push({"role": "user", "content": "fix it"})
	}
	set req = {"model": "mock", "messages": (arr)}

	set http = ##class(%Net.HttpRequest).%New()
	set http.Server = "localhost"
	set http.Port = pPort
	set http.ContentType = "application/json"
	do http.EntityBody.Write(req.%ToJSON())
	set sc = http.Post("/v1/chat/completions")
	if $$$ISERR(sc) quit "HTTP-ERROR: " _ $system.Status.GetErrorText(sc)
	set body = http.HttpResponse.Data.Read(1000000)
	set j = {}.%FromJSON(body)
	quit j.choices.%Get(0).message.content
}

ClassMethod RunAll(pBase As %String = "", pPort As %Integer = 8085)
{
	if pBase = "" set pBase = ##class(DTL.Setup.Installer).ResolveSrcDir($get(^DTL.Config("srcDir")))
	set scenarios = $listbuild(
		$listbuild("ADT_A01_Admit", "transform ADT^A01 sourceDocType 2.3:ADT_A01", "2.3:ADT_A01"),
		$listbuild("ADT_A08_Update", "transform ADT^A08 sourceDocType 2.3:ADT_A01", "2.3:ADT_A01"),
		$listbuild("ORU_R01_LabResult", "transform ORU^R01 sourceDocType 2.3:ORU_R01", "2.3:ORU_R01"))
	set ptr = 0, allok = 1
	while $listnext(scenarios, ptr, row) {
		set name = $listget(row, 1), utext = $listget(row, 2), docin = $listget(row, 3)
		set in = ..ReadFile(pBase _ "inputs/" _ name _ ".hl7")
		set out = ..ReadFile(pBase _ "outputs/" _ name _ ".hl7")
		write !, "==== ", name, " ====", !
		// Expectations per stage: 0=broken(no compile), 1=wrong(compile+run, no match), 2=correct(match)
		set expect = $listbuild("broken", "wrong", "correct")
		for stage = 0:1:2 {
			set raw = ..CallMock(utext, stage, pPort)
			set src = ##class(DTL.Util.Extractor).Extract(raw, .cn, .valid)
			set cls = "DTL.Generated.MockTest" _ $tr(name, "_", "")
			set res = ##class(DTL.Util.Verifier).VerifyAll(src, in, out, docin, "CompileMatch", .cls)
			set tag = $listget(expect, stage + 1)
			set desc = "compiled=" _ res.compiled _ " ran=" _ res.ran _ " matched=" _ res.matched _ " score=" _ $fnumber(res.score, "", 3)
			// Define pass criteria per stage.
			if tag = "broken" { set ok = ('res.compiled) }
			elseif tag = "wrong" { set ok = (res.compiled && res.ran && 'res.matched) }
			else { set ok = (res.compiled && res.ran && res.matched) }
			if 'ok set allok = 0
			write "  stage ", stage, " (", tag, "): ", $select(ok:"PASS", 1:"FAIL"), "  [", desc, "]", !
			if (tag = "broken") && ('res.compiled) write "      (compile error as expected: ", $piece(res.compileErrors, ":", 1), "...)", !
			do:##class(%Dictionary.CompiledClass).%ExistsId(cls) $system.OBJ.Delete(cls, "-d")
		}
	}
	write !, $select(allok:"MOCK CURRICULUM VALID — broken->wrong->correct all behave as intended", 1:"MOCK CURRICULUM FAILED"), !
}

}
