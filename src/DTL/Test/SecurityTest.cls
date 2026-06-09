/// Security regression: proves that a malicious LLM reply cannot execute
/// arbitrary ObjectScript at compile time, and that generated classes are always
/// confined to the DTL.Generated.* package. Run:
///   do ##class(DTL.Test.SecurityTest).RunAll()
Class DTL.Test.SecurityTest Extends %RegisteredObject
{

ClassMethod RunAll()
{
	set allok = 1

	write "==== 1. CodeMode=generator injection is neutralized ====", !
	// A "valid-looking" DTL class that ALSO smuggles a generator method which would
	// run arbitrary code at compile time. The hardened CompileDTL must extract only
	// the <transform> and never compile the malicious method.
	kill ^DTLPwned
	set nl = $char(10)
	set evil = "Class DTL.Generated.Evil Extends Ens.DataTransformDTL [ DependsOn = EnsLib.HL7.Message ]" _ nl
	set evil = evil _ "{" _ nl
	set evil = evil _ "ClassMethod Pwn() [ CodeMode = generator ]" _ nl
	set evil = evil _ "{" _ nl
	set evil = evil _ " do %code.WriteLine("" set ^DTLPwned=1"")" _ nl
	set evil = evil _ " quit $$$OK" _ nl
	set evil = evil _ "}" _ nl
	set evil = evil _ "XData DTL [ XMLNamespace = ""http://www.intersystems.com/dtl"" ]" _ nl
	set evil = evil _ "{" _ nl
	set evil = evil _ "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' sourceDocType='2.3:ADT_A01' targetDocType='2.5:ADT_A01' create='copy' language='objectscript'>" _ nl
	set evil = evil _ "<assign value='""2.5""' property='target.{MSH:12}' action='set'/>" _ nl
	set evil = evil _ "</transform>" _ nl
	set evil = evil _ "}" _ nl
	set evil = evil _ "}" _ nl

	set cls = "Evil"
	set sc = ##class(DTL.Util.Verifier).CompileDTL(evil, .cls, .err)
	set pwned = (+$get(^DTLPwned) = 1)
	set confined = ($extract(cls, 1, 14) = "DTL.Generated.")
	set compiledClean = $$$ISOK(sc)
	write "  compiled (transform only)=", compiledClean, "  classNamePinned=", cls, !
	write "  ^DTLPwned set? ", pwned, "  (must be 0)", !
	if pwned set allok = 0
	if 'confined set allok = 0
	// The compiled class must NOT have a Pwn method (only the DTL transform).
	set hasPwn = ##class(%Dictionary.CompiledMethod).%ExistsId(cls _ "||Pwn")
	write "  injected Pwn method present? ", hasPwn, "  (must be 0)", !
	if hasPwn set allok = 0
	do:##class(%Dictionary.CompiledClass).%ExistsId(cls) $system.OBJ.Delete(cls, "-d")
	kill ^DTLPwned

	write !, "==== 2. LLM-chosen package is forced to DTL.Generated.* ====", !
	set sneaky = "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' sourceDocType='2.3:ADT_A01' targetDocType='2.5:ADT_A01' create='copy' language='objectscript'><assign value='""x""' property='target.{MSH:12}' action='set'/></transform>"
	set cls2 = "Ens.System.Hijack"
	set sc2 = ##class(DTL.Util.Verifier).CompileDTL(sneaky, .cls2)
	write "  requested 'Ens.System.Hijack' -> got '", cls2, "'  (must start DTL.Generated.)", !
	if $extract(cls2, 1, 14) '= "DTL.Generated." set allok = 0
	do:##class(%Dictionary.CompiledClass).%ExistsId(cls2) $system.OBJ.Delete(cls2, "-d")

	write !, "==== 3. empty-vs-empty matches under tolerance ====", !
	set cmp = ##class(DTL.Util.Verifier).Compare("", "", "CompileMatchTolerance", 0.85)
	write "  identical=", cmp.identical, " score=", cmp.score, " matched=", cmp.matched, "  (matched must be 1)", !
	if 'cmp.matched set allok = 0

	write !, $select(allok:"SECURITY TESTS PASS", 1:"SECURITY TESTS FAILED"), !
}

}
