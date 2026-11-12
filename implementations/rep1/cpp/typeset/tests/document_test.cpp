#include <gtest/gtest.h>

#include "typeset/document.hpp"

using namespace typeset;

namespace {
std::string errorOf(std::string_view doc) {
    try {
        Document::parse(doc);
    } catch (const Error& e) {
        return e.format();
    }
    return "no error";
}
}  // namespace

TEST(Document, ParsesParagraphsAndContinuationLines) {
    Document d = Document::parse("one two\nthree\n\nfour\n");
    ASSERT_EQ(d.blocks.size(), 2u);
    EXPECT_EQ(d.blocks[0]->kind, BlockKind::Paragraph);
    EXPECT_EQ(plainText(d.blocks[0]->text), "one two three");
    EXPECT_EQ(plainText(d.blocks[1]->text), "four");
}

TEST(Document, HeadingTakesNoContinuation) {
    Document d = Document::parse("@h1 Title\nbody\n");
    ASSERT_EQ(d.blocks.size(), 2u);
    EXPECT_EQ(d.blocks[0]->kind, BlockKind::Heading);
    EXPECT_EQ(d.blocks[0]->plain, "Title");
    EXPECT_TRUE(d.blocks[0]->numbered);
    EXPECT_EQ(d.blocks[1]->kind, BlockKind::Paragraph);
    Document star = Document::parse("@h2* Plain\n");
    EXPECT_FALSE(star.blocks[0]->numbered);
    EXPECT_EQ(star.blocks[0]->level, 2);
}

TEST(Document, InlineStylesFormAStyleTree) {
    Document d = Document::parse("a {b|{i|x}} y\n");
    const InlineText& t = d.blocks[0]->text;
    // a, glue, x, glue, y
    ASSERT_EQ(t.units.size(), 5u);
    EXPECT_EQ(t.units[2].c, U'x');
    int style = t.units[2].style;
    ASSERT_GT(style, 0);
    EXPECT_EQ(t.styles[style].op, 'i');
    EXPECT_EQ(t.styles[t.styles[style].parent].op, 'b');
}

TEST(Document, SpacesCollapseAndEdgesTrim) {
    Document d = Document::parse("  a   b  \n");
    const auto& u = d.blocks[0]->text.units;
    ASSERT_EQ(u.size(), 3u);
    EXPECT_EQ(u[1].kind, Unit::Glue);
}

TEST(Document, EscapesAndDiscretionaryPoints) {
    Document d = Document::parse("a\\-b\\ c~d\\{\n");
    const auto& u = d.blocks[0]->text.units;
    EXPECT_EQ(u[1].kind, Unit::Disc);
    EXPECT_EQ(u[3].kind, Unit::RigidSpace);
    EXPECT_EQ(u[5].kind, Unit::RigidSpace);
    EXPECT_EQ(u.back().c, U'{');
}

TEST(Document, BackslashAtLineEndEscapesTheJoiningSpace) {
    Document d = Document::parse("ghi\\\n  jkl\n");
    const auto& u = d.blocks[0]->text.units;
    ASSERT_EQ(u.size(), 7u);
    EXPECT_EQ(u[3].kind, Unit::RigidSpace);
}

TEST(Document, FootnotesAreNumberedInSourceOrder) {
    Document d = Document::parse("A{n|one} B{n|two {b|bold}}\n");
    ASSERT_EQ(d.footnotes.size(), 2u);
    EXPECT_EQ(plainText(d.footnotes[0]), "one");
    EXPECT_EQ(plainText(d.footnotes[1]), "two bold");
    int marks = 0;
    for (const Unit& u : d.blocks[0]->text.units)
        if (u.kind == Unit::Mark) EXPECT_EQ(u.footnote, ++marks);
    EXPECT_EQ(marks, 2);
}

TEST(Document, ListsTablesAndAttributes) {
    Document d = Document::parse(
        "@ol start=4\n@li One\n@li Two\ncont\n@ul\n@li Nested\n@end\n@end\n"
        "@table cols=2 align=lr\na | b\n@hrule\nc | d\n@end\n");
    ASSERT_EQ(d.blocks.size(), 2u);
    const Block& ol = *d.blocks[0];
    EXPECT_EQ(ol.kind, BlockKind::OList);
    EXPECT_EQ(ol.start, 4);
    ASSERT_EQ(ol.children.size(), 2u);
    EXPECT_EQ(plainText(ol.children[1]->text), "Two cont");
    ASSERT_EQ(ol.children[1]->children.size(), 1u);
    const Block& tbl = *d.blocks[1];
    EXPECT_EQ(tbl.cols, 2);
    EXPECT_EQ(tbl.colAlign, "lr");
    ASSERT_EQ(tbl.elements.size(), 3u);
    EXPECT_TRUE(tbl.elements[1].hrule);
}

TEST(Document, DocMetadataAndToc) {
    Document d = Document::parse("@doc\ntitle = My Book\nauthor=Me\n@end\n@toc title=\"All Parts\"\ntext\n");
    EXPECT_TRUE(d.hasDoc);
    EXPECT_EQ(d.title, "My Book");
    EXPECT_EQ(d.author, "Me");
    EXPECT_EQ(d.date, "");
    EXPECT_TRUE(d.hasToc);
    EXPECT_EQ(*d.tocTitle, "All Parts");
}

TEST(Document, PreIsVerbatim) {
    Document d = Document::parse("@pre\n  x {b|\n\ny  \n@end\n");
    const Block& pre = *d.blocks[0];
    ASSERT_EQ(pre.lines.size(), 3u);
    EXPECT_EQ(pre.lines[0], "  x {b|");
    EXPECT_EQ(pre.lines[1], "");
    EXPECT_EQ(pre.lines[2], "y");
}

TEST(DocumentErrors, InlineErrors) {
    EXPECT_EQ(errorOf("@h1 Title\n{z|oops}\n"), "document.cdx:2:1: unknown-inline");
    EXPECT_EQ(errorOf("a {b|c {i|d}\n"), "document.cdx:1:3: unclosed-inline");
    EXPECT_EQ(errorOf("ab}\n"), "document.cdx:1:3: stray-brace");
    EXPECT_EQ(errorOf("a\\q\n"), "document.cdx:1:2: bad-escape");
    EXPECT_EQ(errorOf("abc\\\n"), "document.cdx:1:4: bad-escape");
    EXPECT_EQ(errorOf("a{n|b{n|c}}\n"), "document.cdx:1:6: nested-footnote");
    EXPECT_EQ(errorOf("@h1 a{n|b}\n"), "document.cdx:1:6: footnote-not-allowed");
}

TEST(DocumentErrors, BlockStructure) {
    EXPECT_EQ(errorOf("@bogus\n"), "document.cdx:1:1: unknown-block");
    EXPECT_EQ(errorOf("@h1x t\n"), "document.cdx:1:1: unknown-block");
    EXPECT_EQ(errorOf("@end\n"), "document.cdx:1:1: unexpected-end");
    EXPECT_EQ(errorOf("@q\ntext\n"), "document.cdx:3:1: missing-end");
    EXPECT_EQ(errorOf("@hrule\n"), "document.cdx:1:1: block-not-allowed");
    EXPECT_EQ(errorOf("@li x\n"), "document.cdx:1:1: block-not-allowed");
    EXPECT_EQ(errorOf("@toc\n@toc\n"), "document.cdx:2:1: duplicate-toc");
    EXPECT_EQ(errorOf("para\n@toc\n"), "document.cdx:2:1: block-not-allowed");
    EXPECT_EQ(errorOf("@ul\ntext\n@end\n"), "document.cdx:2:1: text-not-allowed");
    EXPECT_EQ(errorOf("@doc\nfoo bar\n@end\n"), "document.cdx:2:1: bad-syntax");
    EXPECT_EQ(errorOf("@doc\nfoo = bar\n@end\n"), "document.cdx:2:1: unknown-meta");
    EXPECT_EQ(errorOf("@doc\ntitle = a\ntitle = b\n@end\n"), "document.cdx:3:1: duplicate-meta");
}

TEST(DocumentErrors, AttributeChecksRunInOrder) {
    EXPECT_EQ(errorOf("@table align=xyz\n"), "document.cdx:1:1: missing-attribute");
    EXPECT_EQ(errorOf("@table cols=0 foo=1\n"), "document.cdx:1:15: bad-attribute");
    EXPECT_EQ(errorOf("@table cols=2\n@vspace height=abc\n@end\n"), "document.cdx:2:1: block-not-allowed");
    EXPECT_EQ(errorOf("@end foo=1\n"), "document.cdx:1:6: bad-attribute");
    EXPECT_EQ(errorOf("@fig height=\"10pt\"x\n@end\n"), "document.cdx:1:13: bad-attribute-value");
    EXPECT_EQ(errorOf("@vspace height=\n"), "document.cdx:1:16: bad-attribute-value");
    EXPECT_EQ(errorOf("@table cols=3 align=ll\n@end\n"), "document.cdx:1:21: bad-attribute-value");
}

TEST(DocumentErrors, TableRows) {
    EXPECT_EQ(errorOf("@table cols=2\na | b | c\n@end\n"), "document.cdx:2:1: cell-count");
    // the row is split before the inline markup is parsed: `{b|x}` is two cells
    EXPECT_EQ(errorOf("@table cols=2\n{b|x} | y\n@end\n"), "document.cdx:2:1: cell-count");
    EXPECT_EQ(errorOf("@table cols=3\n{b|x} | y\n@end\n"), "document.cdx:2:1: unknown-inline");
    EXPECT_EQ(errorOf("@table cols=2\na\\|b | c\n@end\n"), "no error");
}

TEST(DocumentErrors, FigureCaptionIsScannedAtEnd) {
    EXPECT_EQ(errorOf("@fig height=1pt\nbad }\n@toc\n"), "document.cdx:3:1: block-not-allowed");
    EXPECT_EQ(errorOf("@fig height=1pt\nbad }\n@end\n"), "document.cdx:2:5: stray-brace");
}
