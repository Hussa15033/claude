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


# Strategy used when laying out a page. The Healthlink spec (and most spec
# documents) draws ruled tables, so "lines" reconstructs columns far more
# faithfully than the text-density heuristic, which shreds wide DESCRIPTION
# cells into ragged sub-columns.
_TABLE_SETTINGS = {
    "vertical_strategy": "lines",
    "horizontal_strategy": "lines",
    "snap_y_tolerance": 4,
    "join_x_tolerance": 4,
    "intersection_tolerance": 4,
}


def _pdf_to_md(path, stats):
    """PDF -> Markdown. Prefer pdfplumber (keeps tables); fall back to pypdf.

    Layout-aware: on each page the ruled tables and the free text between/around
    them are emitted in true reading order (top-to-bottom), and text that falls
    *inside* a table's bounding box is suppressed so table rows are not also
    dumped a second time as garbled flowed text (the previous behaviour, which
    doubled the page and confused the model). Records page/table/empty-page
    counts in `stats` for the confidence score."""
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
                blocks, n_tables, had_text = _page_blocks(page)
                tables += n_tables
                if not had_text and n_tables == 0:
                    empty += 1
                for block in blocks:
                    if block:
                        parts.append(block)
        stats["method"] = "pdfplumber+lines"
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


def _page_blocks(page):
    """Return (ordered_blocks, n_tables, had_text) for one page.

    Tables are rendered to GitHub pipe-table markdown; everything else becomes
    plain text paragraphs. Blocks are ordered by vertical position so a heading
    that precedes a table stays before it, and trailing prose after a table
    stays after it."""
    try:
        found = page.find_tables(table_settings=_TABLE_SETTINGS) or []
    except Exception:
        found = []
    # Drop tables with no usable content (stray ruled boxes).
    tbls = []
    for t in found:
        try:
            rows = t.extract()
        except Exception:
            continue
        if rows and any(any((c or "").strip() for c in r) for r in rows):
            tbls.append((t.bbox, rows))

    boxes = [b for b, _ in tbls]

    def _inside(word):
        cx = (word["x0"] + word["x1"]) / 2.0
        cy = (word["top"] + word["bottom"]) / 2.0
        for (x0, top, x1, bottom) in boxes:
            if x0 - 1 <= cx <= x1 + 1 and top - 1 <= cy <= bottom + 1:
                return True
        return False

    try:
        words = page.extract_words(use_text_flow=False) or []
    except Exception:
        words = []
    outside = [w for w in words if not _inside(w)]
    had_text = bool(outside) or bool(words)

    # Build ordered (top, kind, payload) blocks.
    items = []
    for bbox, rows in tbls:
        items.append((bbox[1], _rows_to_md_table(rows)))
    # Group outside-words into lines, then contiguous lines into paragraphs.
    for top, line in _words_to_lines(outside):
        items.append((top, line))

    items.sort(key=lambda x: x[0])
    # Merge consecutive plain-text lines into paragraph blocks; keep tables
    # standalone (they already contain newlines / start with "|").
    blocks = []
    buf = []
    for _, payload in items:
        if payload.startswith("|"):
            if buf:
                blocks.append(" \n".join(buf))
                buf = []
            blocks.append(payload)
        else:
            buf.append(payload)
    if buf:
        blocks.append(" \n".join(buf))
    return blocks, len(tbls), had_text


def _words_to_lines(words):
    """Group words sharing a baseline into single text lines -> [(top, text)]."""
    if not words:
        return []
    words = sorted(words, key=lambda w: (round(w["top"]), w["x0"]))
    lines = []
    cur_top = None
    cur = []
    for w in words:
        t = w["top"]
        if cur_top is None or abs(t - cur_top) <= 3:
            cur.append(w)
            cur_top = t if cur_top is None else cur_top
        else:
            lines.append(cur)
            cur = [w]
            cur_top = t
    if cur:
        lines.append(cur)
    out = []
    for ln in lines:
        ln.sort(key=lambda w: w["x0"])
        text = " ".join(w["text"] for w in ln).strip()
        if text:
            out.append((ln[0]["top"], text))
    return out


def _clean_cell(c):
    """Normalise a raw table cell: collapse internal newlines/whitespace, repair
    words split across wrapped lines, and escape pipes so they don't break the
    markdown table grid."""
    s = "" if c is None else str(c)
    # Join hyphen-broken words across wrapped lines: "require-\nments" -> "requirements".
    s = s.replace("-\n", "")
    s = " ".join(s.split())
    return s.replace("|", "\\|").strip()


def _rows_to_md_table(rows):
    """Render raw pdfplumber rows as a GitHub-flavoured pipe table.

    Handles the messy real-world cases in spec PDFs:
      * multi-line column headers (the header label wraps over 2-3 physical
        rows) -> merged into a single header row;
      * fully-empty rows and fully-empty columns -> dropped;
      * pipes inside cells -> escaped;
      * ragged row widths -> padded."""
    grid = [[_clean_cell(c) for c in r] for r in rows if r]
    if not grid:
        return ""
    width = max(len(r) for r in grid)
    grid = [r + [""] * (width - len(r)) for r in grid]

    # Drop fully-empty columns (ruled but unused), keeping at least one column.
    keep = [j for j in range(width) if any(row[j] for row in grid)]
    if keep:
        grid = [[row[j] for j in keep] for row in grid]
        width = len(keep)

    # Drop fully-empty rows.
    grid = [r for r in grid if any(cell for cell in r)]
    if not grid:
        return ""

    # Merge leading header rows: real spec headers wrap, so the first 1-3 rows
    # before the first "data" row collectively form the header. Heuristic: a row
    # is part of the header block while it (a) is among the first few rows and
    # (b) the first cell is empty OR the row has many short all-caps-ish labels.
    header_rows = [grid[0]]
    hi = 1
    while hi < len(grid) and hi < 3:
        row = grid[hi]
        first = grid[0]
        # Continue merging only while this row looks like a wrapped header
        # fragment: most populated cells are short header-ish tokens and there
        # is heavy overlap with empties in the first row.
        nonempty = [c for c in row if c]
        if nonempty and all(len(c) <= 14 for c in nonempty) and \
           sum(1 for c in first if not c) >= width / 2:
            header_rows.append(row)
            hi += 1
        else:
            break

    header = []
    for j in range(width):
        toks = [header_rows[k][j] for k in range(len(header_rows)) if header_rows[k][j]]
        header.append(" ".join(toks).strip())
    body = grid[len(header_rows):]
    if not body:  # header-only "table" -> not worth a grid
        body = []

    head = "| " + " | ".join(header) + " |"
    sep = "| " + " | ".join(["---"] * width) + " |"
    lines = [head, sep] + ["| " + " | ".join(r) + " |" for r in body]
    return "\n".join(lines) + "\n"


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
        if stats.get("method", "").startswith("pdfplumber") and \
           stats.get("tables", 0) == 0:
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
