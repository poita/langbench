from textbuffer import Document
from textbuffer.document import advance


def test_empty_document_has_one_line():
    assert Document().lines == ("",)
    assert Document.from_text("").line_count == 1


def test_clamp():
    doc = Document.from_text("abc\nde")
    assert doc.clamp(10**9, 10**9) == (1, 2)
    assert doc.clamp(0, 10) == (0, 3)


def test_replace_within_line():
    doc = Document.from_text("hello")
    assert doc.replace((0, 1), (0, 3), "XY") == ("el", (0, 3))
    assert doc.text == "hXYlo"


def test_replace_multiline_removal_and_insertion():
    doc = Document.from_text("abc\ndef\nghi")
    removed, end = doc.replace((0, 1), (2, 1), "1\n2\n3")
    assert removed == "bc\ndef\ng"
    assert end == (2, 1)
    assert doc.text == "a1\n2\n3hi"


def test_slice_and_advance():
    doc = Document.from_text("abc\ndef\nghi")
    assert doc.slice((0, 2), (2, 1)) == "c\ndef\ng"
    assert advance((3, 4), "xy") == (3, 6)
    assert advance((3, 4), "x\nyz") == (4, 2)
    assert advance((3, 4), "\n") == (4, 0)
