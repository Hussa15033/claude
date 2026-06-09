"""Document -> Markdown extraction for uploaded spec documents, used by IRIS
(DTL.Util.DocExtract) out-of-process via irispython.

The LLM parses a specification far more reliably as Markdown (headings, tables,
lists preserved) than as a flat text dump, so every document is normalised to
Markdown here:

  * .docx / .doc / .html / .odt / .rtf / .epub  -> Pandoc (via pypandoc), which
    emits GitHub-flavoured Markdown with tables and headings intact.
  * .pdf                                         -> pdfplumber if present (keeps
    table structure as Markdown pipe-tables), else pypdf text. Pandoc cannot read
    PDF, so this path never uses it.
  * .md                                          -> returned verbatim.
  * anything else (txt/csv/hl7/json/...)         -> read as text (already
    Markdown-compatible).

One clean function (`extract`) so ObjectScript never calls underscore-named
Python methods directly. On any failure returns "__EXTRACT_ERROR__<detail>".
"""


def _pandoc_to_md(path, fmt=None):
    """Convert a Pandoc-readable file to GitHub-flavoured Markdown."""
    import pypandoc
    try:
        pypandoc.get_pandoc_version()
    except OSError:
        # No system pandoc on PATH -- fetch a private copy (cached under the
        # user dir) so conversion still works in a bare container.
        pypandoc.download_pandoc()
    return pypandoc.convert_file(path, "gfm", format=fmt,
                                 extra_args=["--wrap=none"])


def _pdf_to_md(path):
    """PDF -> Markdown. Prefer pdfplumber (keeps tables); fall back to pypdf."""
    try:
        import pdfplumber
        parts = []
        with pdfplumber.open(path) as pdf:
            for i, page in enumerate(pdf.pages, 1):
                parts.append("\n\n## Page %d\n" % i)
                for table in (page.extract_tables() or []):
                    parts.append(_rows_to_md_table(table))
                txt = page.extract_text() or ""
                if txt.strip():
                    parts.append(txt)
        return "\n\n".join(parts).strip()
    except Exception:
        from pypdf import PdfReader
        r = PdfReader(path)
        out = []
        for i, pg in enumerate(r.pages, 1):
            out.append("\n\n## Page %d\n" % i)
            out.append(pg.extract_text() or "")
        return "\n".join(out).strip()


def _rows_to_md_table(rows):
    rows = [[("" if c is None else str(c)).replace("\n", " ").strip() for c in r]
            for r in rows if r]
    if not rows:
        return ""
    width = max(len(r) for r in rows)
    rows = [r + [""] * (width - len(r)) for r in rows]
    head = "| " + " | ".join(rows[0]) + " |"
    sep = "| " + " | ".join(["---"] * width) + " |"
    body = ["| " + " | ".join(r) + " |" for r in rows[1:]]
    return "\n".join([head, sep] + body) + "\n"


def extract(path):
    p = (path or "").lower()
    try:
        if p.endswith(".pdf"):
            return _pdf_to_md(path)
        if p.endswith((".docx", ".doc", ".odt", ".rtf", ".epub")):
            return _pandoc_to_md(path)
        if p.endswith((".html", ".htm")):
            return _pandoc_to_md(path, fmt="html")
        # md / txt / csv / hl7 / json / ... already Markdown-compatible.
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception as e:
        # Last-ditch: if a converter failed, try a plain text read of the file so
        # the user still gets *something* usable rather than a hard error.
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                txt = f.read()
            if txt.strip():
                return txt
        except Exception:
            pass
        return "__EXTRACT_ERROR__" + str(e)
