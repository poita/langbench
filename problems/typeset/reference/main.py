#!/usr/bin/env python3
"""Reference implementation of the `typeset` problem (the Codexa engine).

Usage: main.py <input directory> <output directory>
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from settings import CodexaError, parse_settings, default_settings  # noqa: E402
from cdx import Parser  # noqa: E402
from layout import typeset  # noqa: E402

REPORT_KEYS = [
    "pages", "front-pages", "body-pages", "lines", "paragraphs", "headings",
    "tables", "figures", "footnotes", "footnote-split-lines",
    "hyphenated-lines", "overfull-lines", "emergency-lists", "total-demerits",
]


def read_text(path):
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8")


def write_text(path, text):
    with open(path, "wb") as fh:
        fh.write(text.encode("utf-8"))


def run(input_dir, output_dir):
    if not os.path.isdir(output_dir):
        os.makedirs(output_dir)
    document_path = os.path.join(input_dir, "document.cdx")
    settings_path = os.path.join(input_dir, "settings.cfg")
    try:
        if not os.path.exists(document_path):
            raise CodexaError("-", 0, 0, "missing-document")
        if os.path.exists(settings_path):
            settings = parse_settings(read_text(settings_path))
        else:
            settings = default_settings()
        document = Parser(read_text(document_path), settings).parse()
        pages, report = typeset(settings, document)
    except CodexaError as error:
        write_text(os.path.join(output_dir, "error.txt"), error.format() + "\n")
        return
    out = ["layout 1", "pages %d" % len(pages)]
    for index, page in enumerate(pages):
        out.append("page %d %s %d %d %d %d %d %d" % (
            index + 1, page.label, settings.page_width, settings.page_height,
            settings.body_x, settings.body_y, settings.body_width,
            settings.body_height))
        out.extend(page.sorted_lines())
    write_text(os.path.join(output_dir, "layout.txt"), "\n".join(out) + "\n")
    lines = ["report 1"]
    for key in REPORT_KEYS:
        lines.append("%s %d" % (key, report[key]))
    write_text(os.path.join(output_dir, "report.txt"), "\n".join(lines) + "\n")


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: main.py <input dir> <output dir>\n")
        return 2
    run(argv[1], argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
