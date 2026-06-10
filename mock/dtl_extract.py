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

ACCURACY: extraction is the first place a spec can silently go wrong (scanned/
image PDFs yield empty text, multi-column layouts scramble, tables collapse). So
`extract` now ALSO computes a confidence signal and returns it as a machine-
readable first line:

    __EXTRACT_META__{"confidence":0.0-1.0,"pages":N,"chars":N,"tables":N,
                     "emptyPages":N,"method":"pdfplumber|pypdf|pandoc|text",
                     "warnings":[...]}\n
    <the extracted markdown follows>

so IRIS can flag a low-confidence extraction for MANDATORY human review (and the
UI can show the warnings) instead of trusting garbage. On any failure returns
"__EXTRACT_ERROR__<detail>".
"""

import json


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


def _pdf_to_md(path, stats):
    """PDF -> Markdown. Prefer pdfplumber (keeps tables); fall back to pypdf.
    Records page/table/empty-page counts in `stats` for the confidence score."""
    try:
        import pdfplumber
        parts = []
        pages = 0
        empty = 0
        tables = 0
        with pdfplumber.open(path) as pdf:
            for i, page in enumerate(pdf.pages, 1):
                pages += 1
                parts.append("\n\n## Page %d\n" % i)
                page_tables = page.extract_tables() or []
                tables += len(page_tables)
                for table in page_tables:
                    parts.append(_rows_to_md_table(table))
                txt = page.extract_text() or ""
                if txt.strip():
                    parts.append(txt)
                elif not page_tables:
                    empty += 1
        stats["method"] = "pdfplumber"
        stats["pages"] = pages
        stats["tables"] = tables
        stats["emptyPages"] = empty
        return "\n\n".join(parts).strip()
    except Exception:
        from pypdf import PdfReader
        r = PdfReader(path)
        out = []
        empty = 0
        for i, pg in enumerate(r.pages, 1):
            out.append("\n\n## Page %d\n" % i)
            t = pg.extract_text() or ""
            if not t.strip():
                empty += 1
            out.append(t)
        stats["method"] = "pypdf"
        stats["pages"] = len(r.pages)
        stats["tables"] = 0
        stats["emptyPages"] = empty
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


def _confidence(text, stats, is_pdf):
    """Heuristic 0..1 confidence that the extracted markdown faithfully represents
    the document, plus human-readable warnings. Conservative: when in doubt, lower
    the score so the spec is routed to human review rather than trusted blindly."""
    warnings = []
    text = text or ""
    chars = len(text.strip())
    stats["chars"] = chars
    score = 1.0

    if chars < 200:
        score -= 0.5
        warnings.append("Very little text was extracted (%d chars) — the document "
                        "may be scanned/image-based (needs OCR) or empty." % chars)

    if is_pdf:
        pages = stats.get("pages", 0) or 0
        empty = stats.get("emptyPages", 0) or 0
        if pages:
            cpp = chars / pages
            if cpp < 80:
                score -= 0.35
                warnings.append("Only ~%d characters per page — likely a scanned "
                                "PDF with no embedded text (OCR required)." % int(cpp))
            if empty and (empty / pages) >= 0.3:
                score -= 0.2
                warnings.append("%d of %d pages produced no text — image-only pages "
                                "are not captured." % (empty, pages))
        if stats.get("method") == "pypdf":
            score -= 0.1
            warnings.append("Fell back to pypdf (table structure not preserved); "
                            "verify any specification tables carefully.")
        # A spec with tables that pdfplumber didn't detect is a common silent loss.
        if stats.get("method") == "pdfplumber" and stats.get("tables", 0) == 0:
            warnings.append("No tables were detected; if the specification uses "
                            "mapping tables, confirm they survived extraction.")

    # Replacement-character ratio (mojibake from a bad encoding).
    if chars:
        repl = text.count("�")
        if repl and (repl / chars) > 0.005:
            score -= 0.2
            warnings.append("Contains unprintable/replacement characters — possible "
                            "encoding problem.")

    if score < 0:
        score = 0.0
    return round(score, 2), warnings


def extract(path):
    p = (path or "").lower()
    stats = {"method": "text", "pages": 0, "tables": 0, "emptyPages": 0}
    is_pdf = p.endswith(".pdf")
    try:
        if is_pdf:
            text = _pdf_to_md(path, stats)
        elif p.endswith((".docx", ".doc", ".odt", ".rtf", ".epub")):
            stats["method"] = "pandoc"
            text = _pandoc_to_md(path)
        elif p.endswith((".html", ".htm")):
            stats["method"] = "pandoc"
            text = _pandoc_to_md(path, fmt="html")
        else:
            # md / txt / csv / hl7 / json / ... already Markdown-compatible.
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        conf, warnings = _confidence(text, stats, is_pdf)
        meta = {"confidence": conf, "pages": stats.get("pages", 0),
                "chars": stats.get("chars", len((text or "").strip())),
                "tables": stats.get("tables", 0),
                "emptyPages": stats.get("emptyPages", 0),
                "method": stats.get("method", "text"), "warnings": warnings}
        return "__EXTRACT_META__" + json.dumps(meta) + "\n" + (text or "")
    except Exception as e:
        # Last-ditch: if a converter failed, try a plain text read of the file so
        # the user still gets *something* usable rather than a hard error.
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                txt = f.read()
            if txt.strip():
                meta = {"confidence": 0.4, "pages": 0, "chars": len(txt.strip()),
                        "tables": 0, "emptyPages": 0, "method": "text-fallback",
                        "warnings": ["Primary extractor failed (%s); used a plain "
                                     "text read — structure may be lost." % e]}
                return "__EXTRACT_META__" + json.dumps(meta) + "\n" + txt
        except Exception:
            pass
        return "__EXTRACT_ERROR__" + str(e)
