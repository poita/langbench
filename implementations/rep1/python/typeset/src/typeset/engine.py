"""The typesetting pipeline: settings + document -> pages -> output files."""

from __future__ import annotations

import os
from dataclasses import dataclass

from .blocks import BlockLayout
from .context import Env
from .errors import CodexaError
from .headers import render_headers
from .output import Page, render_layout, render_report
from .pages import Paginator
from .parser import parse_document
from .settings import Settings, parse_settings
from .toc import toc_items
from .units import roman


@dataclass
class Result:
    """The outcome of a successful run."""

    layout: str  # contents of layout.txt
    report: str  # contents of report.txt
    pages: list[Page]
    settings: Settings


def typeset(document: str | None, settings: str | None = None,
            data_dir: str = "data") -> Result:
    """Typeset a Codexa *document* with optional *settings* text.

    ``document`` is the contents of ``document.cdx`` (``None`` if absent) and
    ``settings`` the contents of ``settings.cfg``.  Font metrics and
    hyphenation patterns are read from *data_dir*.  Raises
    :class:`~typeset.errors.CodexaError` for invalid input.
    """
    if document is None:
        raise CodexaError("-", 0, 0, "missing-document")
    s = parse_settings(settings)
    doc = parse_document(document)
    env = Env(s, data_dir)

    layout = BlockLayout(env)
    items = layout.run(doc.blocks)
    env.stats.footnotes = doc.footnote_count

    def body_label(m: int):
        n = s.page_start + m - 1
        return str(n), n

    body = Paginator(env, items, label_of=body_label, front=False).paginate()
    front: list[Page] = []
    if doc.toc is not None:
        entries = [h for h in layout.headings if not h.star and h.level <= s.toc_depth]
        toc = toc_items(env, doc.toc.title, entries,
                        lambda page: str(s.page_start + page - 1))
        front = Paginator(env, toc, label_of=lambda m: (roman(m), m), front=True).paginate()

    values = dict(doc.meta)
    values["pages"] = str(len(body))
    chapter = section = ""
    for page in front:
        render_headers(env, page, {**values, "page": page.label, "chapter": "", "section": ""})
    for page in body:
        for h in page.headings:
            text = (h.number + " " + h.plain) if h.number else h.plain
            if h.level == 1:
                chapter = text
            elif h.level == 2:
                section = text
        render_headers(env, page, {**values, "page": page.label, "chapter": chapter,
                                   "section": section})
    pages = front + body
    return Result(render_layout(pages, s),
                  render_report(env.stats, len(pages), len(front)), pages, s)


def typeset_directory(input_dir: str, output_dir: str, data_dir: str = "data") -> None:
    """Run the engine on ``<input_dir>/document.cdx`` (+ ``settings.cfg``) and
    write ``layout.txt`` and ``report.txt`` (or ``error.txt``) to *output_dir*."""
    os.makedirs(output_dir, exist_ok=True)

    def read(name: str) -> str | None:
        path = os.path.join(input_dir, name)
        if not os.path.isfile(path):
            return None
        with open(path, "rb") as fh:
            return fh.read().decode("utf-8")

    try:
        result = typeset(read("document.cdx"), read("settings.cfg"), data_dir)
    except CodexaError as err:
        with open(os.path.join(output_dir, "error.txt"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(err.format() + "\n")
        return
    with open(os.path.join(output_dir, "layout.txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(result.layout)
    with open(os.path.join(output_dir, "report.txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(result.report)
