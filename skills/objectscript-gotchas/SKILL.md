---
name: objectscript-gotchas
description: Writing valid InterSystems ObjectScript that compiles and runs the first time. Use when authoring .cls classes or methods, debugging <SYNTAX>/<UNDEFINED>/compile #1043 errors, MAXLEN/#7201 overflow, decomposing compound %Status compile errors, running code through the `iris session` terminal, or generating ObjectScript with an LLM. Covers quit-vs-return in try blocks, terminal heredoc limits, status checking, verbose error logs, %String→%Stream, and dynamic-object access.
---

# Writing valid InterSystems ObjectScript

Hard-won rules that make ObjectScript compile and run correctly the first time.
Every item below was a real failure that cost a debugging cycle.

## 1. `quit <arg>` is ILLEGAL inside a `try {}` block — use `return`

The single most common compile error (`#1043: QUIT argument not allowed`). Inside
a `try{}` (or any `{}` block), an argument'd `QUIT` is ambiguous with "quit the
block", so the compiler rejects `quit "value"`. Use **`return`** to exit a method
with a value from inside a block.

```objectscript
Method Foo() As %String
{
    try {
        if bad return ""        // ✓  NOT: quit ""
        return tValue           // ✓  NOT: quit tValue
    } catch ex {
        return ""               // ✓
    }
}
```

Argumentless `quit` (to exit a `for`/`while` loop) is fine everywhere. A `quit`
with an argument at the **top level** of a method (not in a block) is also fine.

## 2. The `iris session` terminal cannot run multi-line blocks or `$$$` macros

When piping ObjectScript into `iris session IRIS -U USER <<'EOF' ... EOF`, the
terminal evaluates **one physical line at a time** in direct mode:

- **Multi-line `if {}` / `for {}` / `while {}` / `try {}` blocks fail with `<SYNTAX>`.**
  Keep each statement on ONE line, or put real logic in a compiled class/`.mac`
  and call it. A single-line `for x="a","b" { write x,! }` works; a block split
  across lines does not.
- **`$$$macros` are NOT preprocessed** in the terminal. Use the real method:
  `$system.Status.IsOK(sc)` not `$$$ISOK(sc)`, `$system.Status.GetErrorText(sc)`
  not `$$$ISERR`. In compiled `.cls` code the macros are fine.

For anything non-trivial, **write a ClassMethod and call it** rather than fighting
the terminal.

## 3. Always check %Status from APIs that return one

`$system.OBJ.Load/LoadDir/LoadStream`, `%Save()`, `Ens.Director.*` etc. return a
`%Status`. Check it: `if $$$ISERR(sc) ...` (in code) / `if 'sc ...`. Get readable
text with `$system.Status.GetErrorText(sc)` — for compile errors it includes the
line number AND the generated source line, which is gold for self-correction.

Caveat: **`%SYS.Python.Run()` returns a non-OK status even on success** (it
reports a REPL-style result). Don't treat its status as fatal — judge success by
the side effect (see iris-embedded-python skill).

## 4. IRIS class names cannot contain underscores (or punctuation)

`DTL.Generated.Test_ADT_A01` fails to compile with a misleading
`#5351 Class does not exist`. Class-name segments must be `[A-Za-z0-9]`; dots
separate the package. Sanitize any computed/LLM-supplied class name:

```objectscript
ClassMethod SafeName(pName) As %String {
    set out="" for i=1:1:$length(pName) { set c=$extract(pName,i) if (c?1(1A,1N)) set out=out_c }
    if (out'=""),'($extract(out)?1A) set out="X"_out   // must start with a letter
    quit $select(out'="":out,1:"X")
}
```

## 5. `$zhex()` of a binary string returns 0

`$zhex($system.Encryption.GenCryptRand(6))` returns `0` (it expects a number).
To hex-encode random bytes, do it per byte:
`$zconvert($extract($zhex(256+$ascii(byte,i)),2,3),"L")`.

## 6. Dynamic objects (`%DynamicObject`) — access patterns

- Reading a missing property returns `""` (no error) — but you cannot wrap a
  property reference in `$get()`: `$get(obj.foo)` throws
  `<INVALID CLASS> ... does not support MultiDimensional`. Just use `obj.foo`.
- Build arrays with `do arr.%Push(x)` — `%Push` returns the element, so
  `set a=[].%Push(x)` puts the element in `a`, not the array. Build then assign:
  `set a=[] do a.%Push(x)`.
- 0-based access: `obj.choices.%Get(0)`. Iterate: `set it=arr.%GetIterator() while it.%GetNext(.k,.v){...}`.
- `set j={}.%FromJSON(text)` parses; `j.%ToJSON()` serializes.

## 7. `GetErrorText` shows only the TOP wrapper — decompose for the full log

`$system.Status.GetErrorText(sc)` renders only the outermost error of a COMPOUND
status. A failed class compile typically wraps the real cause (a `#1011 Invalid
name`, `#1001 Missing closing quote`, `#1063 Invalid TRY`, …) inside a generic
`#5030`/generator wrapper, so the one line you print hides what actually broke.
Surface everything from BOTH sources and merge:

```objectscript
// (a) explode the compound status into each constituent error
do $system.Status.DecomposeStatus(sc,.errs)   // errs(1),errs(2),... = each message
// (b) capture the LoadStream errorlog array (often has class/method/line context)
set sc=$system.OBJ.LoadStream(stream,"ck/displayerror=0/displaylog=0",.loadErr)
//     walk loadErr(...) with $order; render a node via GetErrorText ONLY when it
//     is a real status: $listvalid(node)&&$system.Status.IsError(node), else use
//     the node text verbatim — otherwise a plain-text node gets wrongly re-wrapped
//     as "#5034 Invalid status code structure".
```
Clean each line (collapse CRLF/tabs, strip a leading `>` continuation marker),
de-dup across the two sources, and number them. This turns one opaque line into the
handful of real syntax errors — invaluable when feeding errors back to an LLM.

## 8. `%String(MAXLEN=...)` overflows on real data — use a `%Stream`

A `%String` property has a hard `MAXLEN` (commonly 32000); `%Save()` of a longer
value raises `#7201`/`#5802 … length longer than MAXLEN allowed of 32000`. Any
field that can hold document/spec/user-supplied text WILL exceed it. Make it a
`%Stream.GlobalCharacter` instead: write `do obj.Prop.Write(text)`, read via a
helper (`do s.Rewind() while 's.AtEnd {set t=t_s.Read(16000)}`), and surface to
JSON by reading the stream. **When you flip a persistent property String→Stream you
must `%KillExtent()` the old rows** (the stored layout changed) — and restart any
running business hosts so they drop stale compiled code (the event-log line
"continuing to run using code from previous version" is the tell that a host is
still mis-storing against the old type).

## 9. HL7 / DTL specifics live in the `dtl-generation` skill

DocType resolution, segment-path grammar, MSH off-by-one, repeating-field
indexes, grouped segments, and `OutputToString()`'s trailing terminator are
documented separately — see the **dtl-generation** skill.

## 10. Method resolution is compile-time, order-independent

A ClassMethod can call another method defined later in the same class. But a
class is only callable from the namespace it's compiled in (e.g. `Security.*`
lives only in `%SYS`, your app classes only in `USER`) — see the
**iris-interop-rest** skill for the cross-namespace trap.
