import pytest

from typeset import CodexaError, typeset

EX5 = """\
layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body serif 10000 38000 27310 15630 "The"
  text body serif 10000 56170 27310 22240 "quick"
  text body serif 10000 80950 27310 25140 "brown"
  text body serif 10000 108630 27310 15810 "fox."
"""

EX11 = """\
layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body mono 9000 20000 26300 48600 "let x = 1"
  text body mono 9000 20000 37300 59400 "  y = x + 2"
"""

EX13 = """\
layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body serif 7000 59720 25117 3444 "1"
  text body serif 10000 38000 28117 21720 "Delta"
  text body serif 10000 65704 28117 32050 "gamma."
  rule footnote 20000 88968 120000 400
  text footnote serif 6000 25048 96216 2952 "1"
  text footnote serif 8000 30000 98216 5864 "A"
  text footnote serif 8000 37896 98216 15984 "short"
  text footnote serif 8000 55912 98216 15800 "note."
"""

EX15 = """\
layout 1
pages 2
page 1 1 200000 120000 20000 20000 160000 80000
  text body serif 10000 38000 27310 24510 "Alpha"
  text body serif 10000 65050 27310 16950 "one."
  text body serif 10000 38000 39310 18290 "Beta"
  text body serif 10000 58830 39310 17420 "two."
page 2 2 200000 120000 20000 20000 160000 80000
  box float 20000 20000 160000 30000
  text float serif 9000 55556 60579 23571 "Figure"
  text float serif 9000 81413 60579 6705 "1."
  text float serif 9000 92118 60579 6597 "A"
  text float serif 9000 101001 60579 25515 "framed"
  text float serif 9000 128802 60579 15642 "box."
"""


def test_one_line_paragraph(data_dir, small_cfg):
    r = typeset("The quick brown fox.\n", small_cfg, data_dir)
    assert r.layout == EX5
    assert "lines 1\n" in r.report and "total-demerits 100\n" in r.report


def test_two_lines_report(data_dir, small_cfg):
    r = typeset("The quick brown fox jumps over the lazy dog.\n", small_cfg, data_dir)
    assert "lines 2\n" in r.report and "total-demerits 3016\n" in r.report


def test_hyphenated_break(data_dir, small_cfg):
    r = typeset("Algorithm integer column every typesetting.\n",
                small_cfg + "par-indent = 0\n", data_dir)
    assert '"typeset-"' in r.layout and '"ting."' in r.layout
    assert "total-demerits 14996\n" in r.report
    assert "hyphenated-lines 1\n" in r.report


def test_preformatted(data_dir, small_cfg):
    r = typeset("@pre\nlet x = 1\n  y = x + 2\n@end\n", small_cfg, data_dir)
    assert r.layout == EX11


def test_footnote(data_dir, small_cfg):
    r = typeset("Delta{n|A short note.} gamma.\n", small_cfg, data_dir)
    assert r.layout == EX13
    assert "footnotes 1\n" in r.report


def test_deferred_figure(data_dir, small_cfg):
    r = typeset("@fig height=30pt\nA framed box.\n@end\nAlpha one.\n\nBeta two.\n",
                small_cfg, data_dir)
    assert r.layout == EX15


def test_table_of_contents_and_headers(data_dir, small_cfg):
    cfg = small_cfg + "header-baseline = 10pt\\nfooter-baseline = 112pt\n".replace("\\n", "\n") \
        + "header-right = {chapter}\nfooter-center = {page}\n"
    doc = "@toc\n@h1 Introduction\nAlpha one.\n@newpage\n@h1 Results\nBeta two.\n"
    r = typeset(doc, cfg, data_dir)
    assert [p.label for p in r.pages] == ["i", "1", "2"]
    assert '  text footer sans 9000 98780 112000 2439 "i"' in r.layout
    assert '  text header sans 9000 127413 10000 4545 "1"' in r.layout
    assert '  text header sans 9000 134487 10000 45513 "Introduction"' in r.layout
    assert "front-pages 1\n" in r.report and "total-demerits 700\n" in r.report


def test_empty_document(data_dir):
    r = typeset("", None, data_dir)
    assert r.layout == "layout 1\npages 0\n"


def test_errors(data_dir, small_cfg):
    with pytest.raises(CodexaError) as e:
        typeset(None, None, data_dir)
    assert e.value.format() == "-:0:0: missing-document"
    with pytest.raises(CodexaError) as e:
        typeset("@h1 Title\n{z|oops}\n", small_cfg, data_dir)
    assert e.value.format() == "document.cdx:2:1: unknown-inline"
    with pytest.raises(CodexaError) as e:
        typeset("fine\n", "page-width = 200pt\nmargin-left = 20px\n", data_dir)
    assert e.value.format() == "settings.cfg:2:15: bad-length"


def test_deterministic(data_dir, small_cfg):
    doc = "Some words to set, with {n|a note} and more text to fill lines.\n" * 5
    assert typeset(doc, small_cfg, data_dir).layout == typeset(doc, small_cfg, data_dir).layout
