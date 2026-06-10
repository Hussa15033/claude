---
name: iris-embedded-python
description: Using Python from InterSystems IRIS — extracting/Markdown-converting text from PDF/DOCX/etc, calling pip-installed libraries, and avoiding the crashes that wedge the instance. Use when calling Python from ObjectScript, extracting or converting document text to Markdown, running pypdf/pdfplumber/pypandoc/python-docx, or debugging SIGSEGV/<ROUTINELOAD invalid cache>/hung-instance issues after Python calls. Strongly recommends the out-of-process irispython + $ZF(-100) pattern.
---

# IRIS Embedded Python — what's safe and what wedges the instance

Python is available in IRIS via `%SYS.Python` and the `irispython` executable.
But **in-process** Embedded Python proved dangerously unstable for document
extraction; the **out-of-process** subprocess pattern is rock-solid. This skill
documents both and recommends the safe one.

## ⚠️ The instability (real, repeated, cost a destroyed database)

- Calling a method on an OREF returned by `##class(%SYS.Python).Import(mod)`
  (e.g. `mod.extract(path)`) **SIGSEGV'd the IRIS call-in process** (`signal 11`
  in messages.log, session exits with code 1).
- Heavy `%SYS.Python.Run()` calls (notably `subprocess`/`pip install` in-process)
  **hung the entire instance and the CSP web gateway** (every HTTP request and
  `iris session` timed out).
- A SIGSEGV can leave a corrupted routine cache: `<ROUTINELOAD> *class
  %SYSTEM.OBJ invalid cache` / `*class X invalid cache`. Fix with
  `docker restart <container>` (NOT a manual `iris stop` — see below).
- **NEVER `iris stop`/`iris start` an instance manually to recover.** Doing so
  mid-operation destroyed the USER database (`IRIS.DAT` vanished;
  namespace "Access Denied"). Recover (from %SYS) with
  `##class(SYS.Database).CreateDatabase("/usr/irissys/mgr/user/")` — the
  Config.Namespaces mapping + interop-enablement survive, only local data is lost.
  Prefer `docker restart` for any recovery.

## ✅ Recommended: out-of-process via `irispython` + `$ZF(-100)`

Put the Python in a one-function helper module on disk, and shell out to
`irispython` capturing stdout to a temp file. A crash is isolated to the child.

`dtl_extract.py` (helper, one clean function — avoids ObjectScript calling
underscore-named methods like `extract_text`). Convert to **Markdown** rather than
flat text: an LLM parses a spec far more reliably with headings/tables/lists
preserved. Route by extension — Pandoc for Office/HTML, pdfplumber (tables!) for
PDF, verbatim for text:
```python
def extract(path):
    p=(path or "").lower()
    try:
        if p.endswith(".pdf"):
            return _pdf_to_md(path)                       # pdfplumber -> md tables, pypdf fallback
        if p.endswith((".docx",".doc",".odt",".rtf",".epub")):
            return _pandoc_to_md(path)                    # pypandoc -> "gfm"
        if p.endswith((".html",".htm")):
            return _pandoc_to_md(path, fmt="html")
        with open(path,"r",encoding="utf-8",errors="replace") as f: return f.read()
    except Exception as e:
        try:                                              # last-ditch: plain text so the user still gets something
            with open(path,"r",encoding="utf-8",errors="replace") as f:
                t=f.read()
            if t.strip(): return t
        except Exception: pass
        return "__EXTRACT_ERROR__"+str(e)

def _pandoc_to_md(path, fmt=None):
    import pypandoc
    try: pypandoc.get_pandoc_version()
    except OSError: pypandoc.download_pandoc()            # no system pandoc in a bare container -> fetch a private copy
    return pypandoc.convert_file(path,"gfm",format=fmt,extra_args=["--wrap=none"])

def _pdf_to_md(path):                                     # pdfplumber keeps table structure; pypdf is the text-only fallback
    try:
        import pdfplumber
        out=[]
        with pdfplumber.open(path) as pdf:
            for i,pg in enumerate(pdf.pages,1):
                out.append("\n\n## Page %d\n"%i)
                for tbl in (pg.extract_tables() or []): out.append(_rows_to_md_table(tbl))
                t=pg.extract_text() or ""
                if t.strip(): out.append(t)
        return "\n\n".join(out).strip()
    except Exception:
        from pypdf import PdfReader
        return "\n".join((pg.extract_text() or "") for pg in PdfReader(path).pages).strip()
```
- **Pandoc cannot read PDF** — never route PDF through pypandoc; use pdfplumber/pypdf.
- `pypandoc.download_pandoc()` fetches a private pandoc binary (cached under the
  user dir) on first use, so conversion works even when no system `pandoc` is on
  PATH (the community container has none).

ObjectScript call (note the `/STDOUT="..."` flag quoting — `""` inside the OS string):
```objectscript
set out=##class(%File).TempFilename("txt")
set py="import sys;sys.path.insert(0,'"_helperDir_"');import dtl_extract;sys.stdout.write(dtl_extract.extract('"_path_"'))"
set rc=$ZF(-100,"/STDOUT="""_out_"""","/usr/irissys/bin/irispython","-c",py)
// read `out` with %Stream.FileCharacter; "" + rc'=0 => failure;
// a leading "__EXTRACT_ERROR__" => the python caught exception text.
```

`$ZF(-100)` syntax that works: `$ZF(-100,"/STDOUT=""file""",program,arg1,arg2,…)`.
A bad flags string throws `<ILLEGAL VALUE>`. `irispython` (`/usr/irissys/bin/irispython`)
shares the instance's Python + installed packages.

## Installing packages so EMBEDDED Python can import them (the right way)

This is the #1 real failure: `ModuleNotFoundError: No module named 'pypdf'` (or
`pdfplumber`/`pypandoc`/`docx`) in the UI/extraction even after a "pip install".
For Markdown extraction the package set is `pypdf pdfplumber pypandoc python-docx`
(import names `pypdf, pdfplumber, pypandoc, docx`). Causes + fix:

- **`irispython` is often NOT on `$PATH`** — a bare `irispython -m pip ...` in a
  setup script silently fails (`command not found`). Discover the binary instead:
  it lives in `$system.Util.BinaryDirectory()` (e.g. `/usr/irissys/bin/irispython`),
  which is cross-OS. `irispython`'s `sys.executable` is usually the system python3.
- **Install INTO the IRIS package dir** so EMBEDDED Python (not just the CLI)
  sees it: `<ManagerDirectory>/python` (e.g. `/usr/irissys/mgr/python`) is FIRST on
  Embedded Python's `sys.path` on every OS. Install there with `--target`:
  ```
  <python-exe> -m pip install --target <mgr>/python --upgrade <packages>
  ```
  After this, `%SYS.Python.Import("pypdf")` and the subprocess interpreter both
  resolve it. Verify: importable from `<mgr>/python/pypdf/__init__.py`.
- Discover both paths from IRIS (cross-OS, never hardcode):
  `##class(%File).ManagerDirectory()` + `"python"` for the target dir, and
  `$system.Util.BinaryDirectory()` for the interpreter. (NB: the class is
  `%SYSTEM.Util` / `$system.Util`, NOT `%System.Util` — the latter throws
  `<CLASS DOES NOT EXIST>`.)
- **Run pip OUT of process** (in-process `%SYS.Python.Run("...pip...")` hung the
  whole instance). `$ZF(-100)` waits synchronously, BUT passing
  `python -m pip install ...` as separate varargs proved flaky (returned in ~10ms
  doing nothing). Two reliable forms: (a) a single shell command string —
  `$ZF(-100,"/SHELL","/bin/sh","-c", "<exe> -m pip install --target <dir> <pkgs> > <log> 2>&1")`
  (on Windows: `cmd /c`); or (b) a 2-arg call to a small launcher .py that runs
  pip via `subprocess.run`. Pick the shell per OS via `$system.Version.GetOS()`
  (`[ "WIN"` → Windows). See `DTL.Util.Py.EnsurePackages`.
- **Check importability out-of-process too** — don't use `%SYS.Python.Run` for the
  check (it can wedge IRIS). Run `<exe> -c "import a,b; open(out,'w').write('1')"`
  via `$ZF(-100,"/SHELL",...)` and read the sentinel file.

## If you MUST use in-process Python (e.g. quick glue)

- `set m=##class(%SYS.Python).Import("mod")` to import; `##class(%SYS.Python).Builtins()`
  for `len`, `getattr`, etc. Underscore-named methods can't be called as `m.extract_text()`
  from ObjectScript — go through `builtins.getattr(obj,"extract_text").__call__()` or a helper.
- `%SYS.Python.Run(code)` returns a non-OK %Status **even on success** — judge by
  side effects (e.g. a value written to a global), not the status.
- Hand data back via a global: `iris.gref('^MyTmp').set([key], value)` from Python,
  read `^MyTmp(key)` in ObjectScript. (`^||process-private` globals did NOT round-trip
  reliably from Python; use a regular global keyed by `$job`.)
- It can still SIGSEGV in the terminal call-in process. Prefer the subprocess pattern.
