// End-to-end tests: documents in, layout.txt / report.txt out. Expected values
// are the worked examples of the specification.
#include <gtest/gtest.h>

#include "typeset/typeset.hpp"

using namespace typeset;

#ifndef TYPESET_TEST_DATA_DIR
#define TYPESET_TEST_DATA_DIR "data"
#endif

namespace {

const char* kSmall =
    "page-width   = 200pt\npage-height  = 120pt\nmargin-top   = 20pt\nmargin-bottom = 20pt\n"
    "margin-left  = 20pt\nmargin-right = 20pt\n";

Result typesetText(const std::string& doc, const std::string& extra = "") {
    Input in;
    in.document = doc;
    in.settings = std::string(kSmall) + extra;
    return run(in, TYPESET_TEST_DATA_DIR);
}

std::string reportValue(const Result& r, const std::string& key) {
    std::size_t p = r.report.find("\n" + key + " ");
    if (p == std::string::npos) return "";
    p += key.size() + 2;
    return r.report.substr(p, r.report.find('\n', p) - p);
}

}  // namespace

TEST(Pipeline, MissingDocument) {
    Input in;
    Result r = run(in, TYPESET_TEST_DATA_DIR);
    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.error, "-:0:0: missing-document\n");
}

TEST(Pipeline, SettingsErrorsComeFirst) {
    Input in;
    in.document = "{z|oops}\n";
    in.settings = "page-width = 200pt\nmargin-left = 20px\n";
    Result r = run(in, TYPESET_TEST_DATA_DIR);
    EXPECT_EQ(r.error, "settings.cfg:2:15: bad-length\n");
}

TEST(Pipeline, DocumentError) {
    Result r = typesetText("@h1 Title\n{z|oops}\n");
    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.error, "document.cdx:2:1: unknown-inline\n");
}

TEST(Pipeline, EmptyDocumentHasNoPages) {
    Result r = typesetText("");
    ASSERT_TRUE(r.ok);
    EXPECT_EQ(r.layout, "layout 1\npages 0\n");
}

TEST(Pipeline, Example5OneLine) {
    Result r = typesetText("The quick brown fox.\n");
    ASSERT_TRUE(r.ok);
    EXPECT_EQ(r.layout,
              "layout 1\npages 1\npage 1 1 200000 120000 20000 20000 160000 80000\n"
              "  text body serif 10000 38000 27310 15630 \"The\"\n"
              "  text body serif 10000 56170 27310 22240 \"quick\"\n"
              "  text body serif 10000 80950 27310 25140 \"brown\"\n"
              "  text body serif 10000 108630 27310 15810 \"fox.\"\n");
    EXPECT_EQ(r.report,
              "report 1\npages 1\nfront-pages 0\nbody-pages 1\nlines 1\nparagraphs 1\nheadings 0\ntables 0\n"
              "figures 0\nfootnotes 0\nfootnote-split-lines 0\nhyphenated-lines 0\noverfull-lines 0\n"
              "emergency-lists 0\ntotal-demerits 100\n");
}

TEST(Pipeline, Example6TwoJustifiedLines) {
    Result r = typesetText("The quick brown fox jumps over the lazy dog.\n");
    ASSERT_TRUE(r.ok);
    EXPECT_NE(r.layout.find("  text body serif 10000 55521 27310 22240 \"quick\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body serif 10000 38910 39310 17480 \"dog.\"\n"), std::string::npos);
    EXPECT_EQ(reportValue(r, "total-demerits"), "3016");
    EXPECT_EQ(reportValue(r, "lines"), "2");
}

TEST(Pipeline, Example7RaggedRight) {
    Result r = typesetText("The quick brown fox jumps over the lazy dog.\n", "align = right\n");
    ASSERT_TRUE(r.ok);
    EXPECT_NE(r.layout.find("  text body serif 10000 49020 27310 15630 \"The\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body serif 10000 128700 39310 12370 \"the\"\n"), std::string::npos);
    EXPECT_EQ(reportValue(r, "total-demerits"), "244");
}

TEST(Pipeline, Example8HyphenatedBreakMergesRuns) {
    Result r = typesetText("Algorithm integer column every typesetting.\n", "par-indent = 0\n");
    ASSERT_TRUE(r.ok);
    EXPECT_NE(r.layout.find("  text body serif 10000 20000 27310 41620 \"Algorithm\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body serif 10000 148380 27310 31620 \"typeset-\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body serif 10000 20000 39310 18120 \"ting.\"\n"), std::string::npos);
    EXPECT_EQ(reportValue(r, "total-demerits"), "14996");
    EXPECT_EQ(reportValue(r, "hyphenated-lines"), "1");
}

TEST(Pipeline, Example9NumberedHeading) {
    Result r = typesetText("@h1 Introduction\nThe quick brown fox.\n");
    ASSERT_TRUE(r.ok);
    EXPECT_NE(r.layout.find("  text body sans-bold 20000 20000 35460 11400 \"1\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body sans-bold 20000 37400 35460 114340 \"Introduction\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body serif 10000 38000 56630 15630 \"The\"\n"), std::string::npos);
    EXPECT_EQ(reportValue(r, "total-demerits"), "200");
}

TEST(Pipeline, Example10NestedListMarkers) {
    Result r = typesetText("@ul\n@li First item.\n@li Second item.\n@ul\n@li Nested one.\n@end\n@end\n");
    ASSERT_TRUE(r.ok);
    EXPECT_NE(r.layout.find("  text body serif 10000 30560 27310 3440 \"\xE2\x80\xA2\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body serif 10000 47060 54850 4940 \"\xE2\x80\x93\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body serif 10000 56000 54850 28070 \"Nested\"\n"), std::string::npos);
    EXPECT_EQ(reportValue(r, "paragraphs"), "0");
}

TEST(Pipeline, Example11Preformatted) {
    Result r = typesetText("@pre\nlet x = 1\n  y = x + 2\n@end\n");
    ASSERT_TRUE(r.ok);
    EXPECT_NE(r.layout.find("  text body mono 9000 20000 26300 48600 \"let x = 1\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body mono 9000 20000 37300 59400 \"  y = x + 2\"\n"), std::string::npos);
    EXPECT_EQ(reportValue(r, "total-demerits"), "0");
}

TEST(Pipeline, Example12TableFits) {
    Result r = typesetText(
        "@table cols=3 align=llr\nItem | Qty | Price\n@hrule\nWidget | 2 | 4.50\nGadget | 11 | 19.95\n@end\n");
    ASSERT_TRUE(r.ok);
    EXPECT_NE(r.layout.find("  rule body 20000 31540 82990 400\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body serif 10000 82550 27310 20440 \"Price\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body serif 10000 80530 52790 22460 \"19.95\"\n"), std::string::npos);
}

TEST(Pipeline, Example13Footnote) {
    Result r = typesetText("Delta{n|A short note.} gamma.\n");
    ASSERT_TRUE(r.ok);
    EXPECT_NE(r.layout.find("  text body serif 7000 59720 25117 3444 \"1\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  rule footnote 20000 88968 120000 400\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text footnote serif 6000 25048 96216 2952 \"1\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text footnote serif 8000 55912 98216 15800 \"note.\"\n"), std::string::npos);
    EXPECT_EQ(reportValue(r, "footnotes"), "1");
}

TEST(Pipeline, Example15DeferredFigure) {
    Result r = typesetText("@fig height=30pt\nA framed box.\n@end\nAlpha one.\n\nBeta two.\n");
    ASSERT_TRUE(r.ok);
    EXPECT_NE(r.layout.find("pages 2\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  box float 20000 20000 160000 30000\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text float serif 9000 55556 60579 23571 \"Figure\"\n"), std::string::npos);
    EXPECT_EQ(reportValue(r, "total-demerits"), "300");
}

TEST(Pipeline, Example16TableOfContents) {
    Result r = typesetText("@toc\n@h1 Introduction\nAlpha one.\n@newpage\n@h1 Results\nBeta two.\n");
    ASSERT_TRUE(r.ok);
    EXPECT_NE(r.layout.find("page 1 i 200000"), std::string::npos);
    EXPECT_NE(r.layout.find("page 2 1 200000"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body sans-bold 20000 20000 35460 82500 \"Contents\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text body serif 10000 175080 59630 4920 \"1\"\n"), std::string::npos);
    EXPECT_EQ(reportValue(r, "front-pages"), "1");
    EXPECT_EQ(reportValue(r, "total-demerits"), "700");
}

TEST(Pipeline, Example18RunningHeaders) {
    Result r = typesetText("@toc\n@h1 Introduction\nAlpha one.\n@newpage\n@h1 Results\nBeta two.\n",
                           "header-baseline = 10pt\nfooter-baseline = 112pt\nheader-right = {chapter}\nfooter-center = {page}\n");
    ASSERT_TRUE(r.ok);
    EXPECT_NE(r.layout.find("  text footer sans 9000 98780 112000 2439 \"i\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text header sans 9000 127413 10000 4545 \"1\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text header sans 9000 134487 10000 45513 \"Introduction\"\n"), std::string::npos);
    EXPECT_NE(r.layout.find("  text footer sans 9000 97727 112000 4545 \"1\"\n"), std::string::npos);
}

TEST(Pipeline, ForcedBreaksNeverMakeBlankPages) {
    Result r = typesetText("one\n@newpage\n@newpage\ntwo\n@newpage\n");
    ASSERT_TRUE(r.ok);
    EXPECT_EQ(reportValue(r, "pages"), "2");
}

TEST(Pipeline, LongDocumentFlowsOntoManyPages) {
    std::string doc;
    for (int i = 0; i < 60; ++i) doc += "Paragraph number " + std::to_string(i) + " has some words in it to fill a line.\n\n";
    Result r = typesetText(doc);
    ASSERT_TRUE(r.ok);
    EXPECT_GT(std::stoi(reportValue(r, "pages")), 3);
    EXPECT_EQ(reportValue(r, "paragraphs"), "60");
}
