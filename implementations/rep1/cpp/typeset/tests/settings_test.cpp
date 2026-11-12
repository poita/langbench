#include <gtest/gtest.h>

#include "typeset/settings.hpp"

using namespace typeset;

namespace {
Error errorOf(std::string_view cfg) {
    try {
        Settings::parse(cfg);
    } catch (const Error& e) {
        return e;
    }
    ADD_FAILURE() << "expected an error for: " << cfg;
    return {};
}
std::string fmt(std::string_view cfg) { return errorOf(cfg).format(); }
}  // namespace

TEST(Settings, Defaults) {
    Settings s = Settings::parse(std::nullopt);
    EXPECT_EQ(s.pageWidth, 612000);
    EXPECT_EQ(s.bodyWidth(), 468000);
    EXPECT_EQ(s.bodyHeight(), 648000);
    EXPECT_EQ(s.footerBaseline, 756000);
    EXPECT_EQ(s.footnoteMaxHeight, 324000);
    EXPECT_EQ(s.align, Align::Justify);
    EXPECT_EQ(s.tocLeader, ".");
}

TEST(Settings, DerivedDefaultsFollowExplicitValues) {
    Settings s = Settings::parse("page-height = 400pt\n");
    EXPECT_EQ(s.footerBaseline, 364000);
    EXPECT_EQ(s.footnoteMaxHeight, floorDiv(s.bodyHeight(), 2));
}

TEST(Settings, LengthLiterals) {
    EXPECT_EQ(parseLength("2.5pt"), 2500);
    EXPECT_EQ(parseLength("0.5pt"), 500);
    EXPECT_EQ(parseLength("1.5mm"), 4252);
    EXPECT_EQ(parseLength("-6pt"), -6000);
    EXPECT_EQ(parseLength("734"), 734);
    EXPECT_EQ(parseLength("1in"), 72000);
    EXPECT_EQ(parseLength("2pc"), 24000);
    EXPECT_EQ(parseLength("1cm"), 28350);
    for (const char* bad : {"", "+1pt", "1.2345pt", ".5pt", "5.pt", "1px", "1 pt", "pt", "--1"})
        EXPECT_FALSE(parseLength(bad)) << bad;
}

TEST(Settings, IntegerLiterals) {
    EXPECT_EQ(parseInteger("12"), 12);
    EXPECT_EQ(parseInteger("-3"), -3);
    EXPECT_FALSE(parseInteger("+3"));
    EXPECT_FALSE(parseInteger("3.0"));
    EXPECT_FALSE(parseInteger(""));
}

TEST(Settings, CommentsBlankLinesAndWhitespace) {
    Settings s = Settings::parse("# comment\n\n   \t\n  tolerance\t=\t5 \n\t# indented comment\n");
    EXPECT_EQ(s.tolerance, 5);
    // a '#' inside a value is literal, not a comment
    EXPECT_EQ(fmt("tolerance = 5 # c\n"), "settings.cfg:1:13: bad-integer");
}

TEST(Settings, ErrorPositions) {
    EXPECT_EQ(fmt("page-width = 200pt\nmargin-left = 20px\n"), "settings.cfg:2:15: bad-length");
    EXPECT_EQ(fmt("page-width 200pt\n"), "settings.cfg:1:1: bad-syntax");
    EXPECT_EQ(fmt("  nope = 1\n"), "settings.cfg:1:3: unknown-setting");
    EXPECT_EQ(fmt("align = left\nalign = left\n"), "settings.cfg:2:1: duplicate-setting");
    EXPECT_EQ(fmt("margin-top =\n"), "settings.cfg:1:13: bad-length");
    EXPECT_EQ(fmt("tolerance = x\n"), "settings.cfg:1:13: bad-integer");
    EXPECT_EQ(fmt("hyphenate = yes\n"), "settings.cfg:1:13: bad-boolean");
    EXPECT_EQ(fmt("align = middle\n"), "settings.cfg:1:9: bad-enum");
    EXPECT_EQ(fmt("body-font = fancy\n"), "settings.cfg:1:13: unknown-font");
    EXPECT_EQ(fmt("hyphen-patterns = french\n"), "settings.cfg:1:19: unknown-patterns");
    EXPECT_EQ(fmt("widows = 0\n"), "settings.cfg:1:10: bad-value");
    EXPECT_EQ(fmt("margin-top = -1pt\n"), "settings.cfg:1:14: bad-value");
}

TEST(Settings, TextValues) {
    Settings s = Settings::parse("header-left = a{page}\\{b\\}\\\\{title}\n");
    ASSERT_EQ(s.slotsOdd[HeaderLeft].size(), 4u);
    EXPECT_FALSE(s.slotsOdd[HeaderLeft][0].placeholder);
    EXPECT_EQ(s.slotsOdd[HeaderLeft][0].text, "a");
    EXPECT_TRUE(s.slotsOdd[HeaderLeft][1].placeholder);
    EXPECT_EQ(s.slotsOdd[HeaderLeft][2].text, "{b}\\");
    EXPECT_EQ(s.slotsOdd[HeaderLeft][3].text, "title");
    EXPECT_EQ(fmt("header-left = \\{page}\n"), "settings.cfg:1:21: stray-brace");
    EXPECT_EQ(fmt("header-left = }\\q\n"), "settings.cfg:1:15: stray-brace");
    EXPECT_EQ(fmt("header-left = {pa\\ge}\n"), "settings.cfg:1:15: unknown-placeholder");
    EXPECT_EQ(fmt("header-left = {page\n"), "settings.cfg:1:15: unknown-placeholder");
    EXPECT_EQ(fmt("header-left = a\\q\n"), "settings.cfg:1:16: bad-escape");
}

TEST(Settings, EvenSlotsFallBackToPlainSlots) {
    Settings s = Settings::parse("header-left = L\nheader-right-even = R\n");
    EXPECT_EQ(s.slotsEven[HeaderLeft][0].text, "L");
    EXPECT_EQ(s.slotsEven[HeaderRight][0].text, "R");
    EXPECT_TRUE(s.slotsOdd[HeaderRight].empty());
}

TEST(Settings, LiteralTextSettingsRejectPlaceholders) {
    EXPECT_EQ(fmt("toc-title = {title}\n"), "settings.cfg:1:13: bad-value");
    EXPECT_EQ(fmt("toc-leader = . .\n"), "settings.cfg:1:14: bad-value");
    EXPECT_EQ(fmt("toc-leader = 123456789\n"), "settings.cfg:1:14: bad-value");
    EXPECT_EQ(fmt("figure-caption-prefix = {page}\n"), "settings.cfg:1:25: bad-value");
}

TEST(Settings, BodyRectangleErrorPointsAtLastGeometryKey) {
    EXPECT_EQ(fmt("margin-bottom = 50pt\npage-height = 120pt\nmargin-top = 40pt\nalign = left\n"),
              "settings.cfg:3:14: bad-value");
}
