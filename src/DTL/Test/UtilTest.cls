/// Standalone tests for the utility layer, runnable from the terminal:
///   do ##class(DTL.Test.UtilTest).RunAll()
Class DTL.Test.UtilTest Extends %RegisteredObject
{

ClassMethod ReadFile(path As %String) As %String
{
	set s = ##class(%Stream.FileCharacter).%New()
	do s.LinkToFile(path)
	quit s.Read(1000000)
}

/// Verify each example pair against its reference DTL; print PASS/FAIL.
/// pBase defaults to the source dir resolved by the installer (auto-discovered).
ClassMethod RunAll(pBase As %String = "")
{
	if pBase = "" set pBase = ##class(DTL.Setup.Installer).ResolveSrcDir($get(^DTL.Config("srcDir")))
	write "==== Verifier: example pairs vs reference DTLs ====", !
	set rows = $listbuild(
		$listbuild("ADT_A01_Admit", "2.3:ADT_A01"),
		$listbuild("ADT_A08_Update", "2.3:ADT_A01"),
		$listbuild("ORU_R01_LabResult", "2.3:ORU_R01"))
	set ptr = 0, allok = 1
	while $listnext(rows, ptr, row) {
		set name = $listget(row, 1), docin = $listget(row, 2)
		set in = ..ReadFile(pBase _ "inputs/" _ name _ ".hl7")
		set out = ..ReadFile(pBase _ "outputs/" _ name _ ".hl7")
		set frag = ..ReadFile(pBase _ "reference/" _ name _ ".dtl.xml")
		set cls = "DTL.Generated.Test_" _ name
		set res = ##class(DTL.Util.Verifier).VerifyAll(frag, in, out, docin, "CompileMatch", .cls)
		set pass = (res.compiled && res.ran && res.matched && res.identical)
		if 'pass set allok = 0
		write $select(pass:"  PASS  ", 1:"  FAIL  "), name
		write "  (compiled=", res.compiled, " ran=", res.ran, " identical=", res.identical
		write " score=", $fnumber(res.score, "", 3), " diffs=", res.diffCount, ")", !
		if 'pass {
			if res.compileErrors '= "" write "        compileErr: ", res.compileErrors, !
			if res.diffCount > 0 write ##class(DTL.Util.Verifier).DiffsToText(res.diffs, 10)
		}
		do $system.OBJ.Delete(cls, "-d")
	}

	write !, "==== Extractor: fenced markdown ====", !
	set raw = "Here is your DTL:" _ $char(10) _ "```objectscript" _ $char(10)
	set raw = raw _ "Class Foo.Bar Extends Ens.DataTransformDTL [ DependsOn = EnsLib.HL7.Message ]" _ $char(10)
	set raw = raw _ "{" _ $char(10) _ "XData DTL [ XMLNamespace = ""http://www.intersystems.com/dtl"" ]" _ $char(10)
	set raw = raw _ "{" _ $char(10) _ "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' create='copy' language='objectscript'></transform>" _ $char(10)
	set raw = raw _ "}" _ $char(10) _ "}" _ $char(10) _ "```" _ $char(10) _ "Hope that helps!"
	set ext = ##class(DTL.Util.Extractor).Extract(raw, .cn, .valid)
	write "  extracted className=", cn, " valid=", valid, !
	write "  starts-with-Class=", ($extract(ext, 1, 5) = "Class"), " ends-with-brace=", ($extract(ext, *) = "}"), " no-fences=", '(ext [ "```"), !

	write !, "==== HL7.DeriveDocType ====", !
	set adt = ..ReadFile(pBase _ "inputs/ADT_A08_Update.hl7")
	set dt = ##class(DTL.Util.HL7).DeriveDocType(adt, .ver, .struct)
	write "  ADT_A08 input -> docType=", dt, " (version=", ver, " structure=", struct, ")  [expect 2.3:ADT_A01]", !

	write !, $select(allok:"ALL EXAMPLE PAIRS PASS", 1:"SOME PAIRS FAILED"), !
}

}
