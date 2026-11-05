module tests.markup_test;

import std.exception : collectException;
import typeset.errors;
import typeset.markup;

private string errorOf(string doc)
{
    auto e = collectException!TypesetError(parseDocument(doc));
    return e is null ? "ok" : e.diag.toString();
}

unittest // the block tree
{
    auto d = parseDocument("@h1 Title\nFirst paragraph\ncontinues.\n\n@ul\n@li One\n@li Two\n@end\n");
    assert(d.blocks.length == 3);
    assert(d.blocks[0].kind == BlockKind.heading && d.blocks[0].level == 1);
    assert(d.blocks[1].kind == BlockKind.paragraph);
    assert(d.blocks[2].kind == BlockKind.ulist && d.blocks[2].children.length == 2);
    assert(d.paragraphs == 1 && d.headings == 1);
    assert(plainText(d.blocks[1].text) == "First paragraph continues.");
}

unittest // inline constructs
{
    auto d = parseDocument("a  {b|b {i|c}}~\\{\\-x\n");
    auto inl = d.blocks[0].text;
    assert(plainText(inl) == "a b c {x");
    size_t discs, rigids;
    foreach (u; inl.units)
    {
        discs += u.kind == UnitKind.disc;
        rigids += u.kind == UnitKind.rigid;
    }
    assert(discs == 1 && rigids == 1);
    assert(inl.styles.length == 3); // root, bold, italic
}

unittest // footnotes are extracted in source order
{
    auto d = parseDocument("One{n|first} two{n|second {b|note}}.\n");
    assert(d.footnotes.length == 2);
    assert(plainText(d.footnotes[1].text) == "second note");
}

unittest // metadata, tables and attributes
{
    auto d = parseDocument("@doc\ntitle = My Title\nauthor = Me\n@end\n@table cols=2 align=lr\na | b\n@hrule\nc | d\n@end\n");
    assert(d.meta.title == "My Title" && d.meta.author == "Me" && d.meta.date == "");
    auto t = d.blocks[0];
    assert(t.cols == 2 && t.colLetters == "lr" && t.rows.length == 3 && t.rows[1].isRule);
}

unittest // inline errors and positions
{
    assert(errorOf("@h1 Title\n{z|oops}\n") == "document.cdx:2:1: unknown-inline");
    assert(errorOf("a {b|c\n") == "document.cdx:1:3: unclosed-inline");
    assert(errorOf("a }\n") == "document.cdx:1:3: stray-brace");
    assert(errorOf("a \\q\n") == "document.cdx:1:3: bad-escape");
    assert(errorOf("x {n|a {n|b}}\n") == "document.cdx:1:8: nested-footnote");
    assert(errorOf("@h1 a{n|b}\n") == "document.cdx:1:6: footnote-not-allowed");
    assert(errorOf("line one\nline {x|y}\n") == "document.cdx:2:6: unknown-inline");
}

unittest // block and attribute errors
{
    assert(errorOf("@wat\n") == "document.cdx:1:1: unknown-block");
    assert(errorOf("@end\n") == "document.cdx:1:1: unexpected-end");
    assert(errorOf("@q\ntext\n") == "document.cdx:3:1: missing-end");
    assert(errorOf("@li x\n") == "document.cdx:1:1: block-not-allowed");
    assert(errorOf("@hrule\n") == "document.cdx:1:1: block-not-allowed");
    assert(errorOf("x\n@toc\n") == "document.cdx:2:1: block-not-allowed");
    assert(errorOf("@toc\n@toc\n") == "document.cdx:2:1: duplicate-toc");
    assert(errorOf("@table\n") == "document.cdx:1:1: missing-attribute");
    assert(errorOf("@table cols=0\n") == "document.cdx:1:13: bad-attribute-value");
    assert(errorOf("@table cols=2 foo=1\n") == "document.cdx:1:15: bad-attribute");
    assert(errorOf("@table cols=2\na | b | c\n@end\n") == "document.cdx:2:1: cell-count");
    assert(errorOf("@ul\ntext\n@end\n") == "document.cdx:2:1: text-not-allowed");
    assert(errorOf("@doc\nfoo = 1\n@end\n") == "document.cdx:2:1: unknown-meta");
    assert(errorOf("@doc\ntitle = a\ntitle = b\n@end\n") == "document.cdx:3:1: duplicate-meta");
    assert(errorOf("@end foo=1\n") == "document.cdx:1:6: bad-attribute");
    assert(errorOf("@table cols=1\n@vspace height=abc\n@end\n") == "document.cdx:2:1: block-not-allowed");
}

unittest // preformatted text is verbatim up to the terminator
{
    auto d = parseDocument("@pre\n  a  \n\n@h1 not a heading\n  @end\nafter\n");
    assert(d.blocks[0].preLines == ["  a", "", "@h1 not a heading"]);
    assert(d.blocks[1].kind == BlockKind.paragraph);
}
