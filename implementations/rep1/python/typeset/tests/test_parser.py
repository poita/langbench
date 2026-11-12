import pytest

from typeset import CodexaError, parse_document
from typeset import nodes


def err(text):
    with pytest.raises(CodexaError) as info:
        parse_document(text)
    return info.value.format()


def test_paragraph_continuation_and_blocks():
    doc = parse_document("one\n  two\n\nthree\n@rule\n")
    assert [type(b) for b in doc.blocks] == [nodes.Paragraph, nodes.Paragraph, nodes.Rule]


def test_heading_takes_no_continuation():
    doc = parse_document("@h1 Title\ntext\n")
    assert [type(b) for b in doc.blocks] == [nodes.Heading, nodes.Paragraph]


def test_doc_metadata_and_toc():
    doc = parse_document("@doc\ntitle = A Title\nauthor=Me\n@end\n@toc title=\"Index\"\ntext\n")
    assert doc.meta == {"title": "A Title", "author": "Me", "date": ""}
    assert doc.toc.title == "Index"


def test_list_items_and_nesting():
    doc = parse_document("@ol start=3\n@li a\n  more\n@ul\n@li b\n@end\n@li c\n@end\n")
    lst = doc.blocks[0]
    assert lst.ordered and lst.start == 3 and len(lst.items) == 2
    assert isinstance(lst.items[0].children[0], nodes.ListNode)


def test_table_rows_split_before_inline_parsing():
    doc = parse_document("@table cols=2\na \\| b | c\n@hrule\n@end\n")
    kinds = [e[0] for e in doc.blocks[0].elements]
    assert kinds == ["row", "hrule"]


def test_pre_is_verbatim():
    doc = parse_document("@pre\n  {x} \\ \n\n @end \n")
    assert doc.blocks[0].lines == ["  {x} \\", ""]


@pytest.mark.parametrize("text,expected", [
    ("", None),
    ("@h1x a\n", "document.cdx:1:1: unknown-block"),
    ("@end\n", "document.cdx:1:1: unexpected-end"),
    ("@q\ntext\n", "document.cdx:3:1: missing-end"),
    ("@li x\n", "document.cdx:1:1: block-not-allowed"),
    ("@toc\n@toc\n", "document.cdx:2:1: duplicate-toc"),
    ("@ul\ntext\n@end\n", "document.cdx:2:1: text-not-allowed"),
    ("@table cols=2\na\n@end\n", "document.cdx:2:1: cell-count"),
    ("@table align=xyz\n@end\n", "document.cdx:1:1: missing-attribute"),
    ("@table cols=0 foo=1\n", "document.cdx:1:15: bad-attribute"),
    ("@table cols=2 align=l\n@end\n", "document.cdx:1:21: bad-attribute-value"),
    ("@vspace height=\n", "document.cdx:1:16: bad-attribute-value"),
    ("@fig height=10pt width=\"3pt\"x\n", "document.cdx:1:24: bad-attribute-value"),
    ("@doc\nfoo bar\n@end\n", "document.cdx:2:1: bad-syntax"),
    ("@doc\nsize = 1\n@end\n", "document.cdx:2:1: unknown-meta"),
    ("@doc\ntitle = a\ntitle = b\n@end\n", "document.cdx:3:1: duplicate-meta"),
    ("@fig height=1pt\nabc {z|x}\n@q\n@end\n", "document.cdx:3:1: block-not-allowed"),
    ("@fig height=1pt\nabc {z|x}\n@end\n", "document.cdx:2:5: unknown-inline"),
    ("@h1 a {n|x}\n", "document.cdx:1:7: footnote-not-allowed"),
    ("para {b|x\n@rule\n", "document.cdx:1:6: unclosed-inline"),
])
def test_parser_errors(text, expected):
    if expected is None:
        parse_document(text)
    else:
        assert err(text) == expected
