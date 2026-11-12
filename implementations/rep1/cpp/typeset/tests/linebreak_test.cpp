#include <gtest/gtest.h>

#include "typeset/linebreak.hpp"

using namespace typeset;

#ifndef TYPESET_TEST_DATA_DIR
#define TYPESET_TEST_DATA_DIR "data"
#endif

namespace {

struct Fixture {
    Settings settings = Settings::parse(std::nullopt);
    FontSet fonts = FontSet::load(TYPESET_TEST_DATA_DIR);
    PatternSet patterns = PatternSet::load(TYPESET_TEST_DATA_DIR, "english");

    HList build(const std::string& text, Context ctx) {
        Document d = Document::parse(text + "\n");
        HListBuilder b(settings, fonts, patterns);
        return b.build(d.blocks[0]->text, ctx);
    }
    Context ctx(i64 measure) {
        Context c;
        c.measure = measure;
        c.left = 20000;
        return c;
    }
};

}  // namespace

TEST(HList, TheQuickBrownFoxMatchesExample5) {
    Fixture f;
    HList h = f.build("The quick brown fox.", f.ctx(142000));
    ASSERT_EQ(h.items.size(), 10u);
    EXPECT_EQ(h.items[0].text, "The");
    EXPECT_EQ(h.items[0].width, 15630);
    EXPECT_EQ(h.items[1].kind, Item::Glue);
    EXPECT_EQ(h.items[1].width, 2540);
    EXPECT_EQ(h.items[1].stretch, 1270);
    EXPECT_EQ(h.items[1].shrink, 850);
    EXPECT_EQ(h.items[6].width, 15810);
    EXPECT_EQ(h.items[7].penalty, 10000);
    EXPECT_TRUE(h.items[8].infinite);
    EXPECT_EQ(h.items[9].penalty, -10000);
    EXPECT_EQ(h.breakpoints, (std::vector<int>{1, 3, 5, 9}));
}

TEST(HList, SentenceEndGetsExtraSpace) {
    Fixture f;
    HList h = f.build("end. Next J. Smith", f.ctx(100000));
    ASSERT_GE(h.items.size(), 5u);
    EXPECT_EQ(h.items[1].width, scaleUnits(254 + 112, 10000));
    EXPECT_EQ(h.items[1].stretch, scaleUnits(127 + 63, 10000));
    // "J." does not end a sentence
    for (const Item& it : h.items)
        if (it.kind == Item::Glue && !it.infinite) EXPECT_TRUE(it.width == 3660 || it.width == 2540);
    EXPECT_EQ(h.items[5].width, 2540);
}

TEST(HList, HyphenationSplitsFragmentsIntoBoxes) {
    Fixture f;
    HList h = f.build("typesetting", f.ctx(100000));
    // typeset - t - ing  + 3 final items
    ASSERT_EQ(h.items.size(), 8u);
    EXPECT_EQ(h.items[1].kind, Item::Penalty);
    EXPECT_TRUE(h.items[1].flagged);
    EXPECT_EQ(h.items[1].penalty, 50);
    EXPECT_EQ(h.items[1].preText, "-");
    EXPECT_EQ(h.items[0].text, "typeset");
}

TEST(HList, RaggedAlignmentReplacesGlue) {
    Fixture f;
    Context c = f.ctx(142000);
    c.align = Align::Left;
    HList h = f.build("a b", c);
    EXPECT_EQ(h.items[1].stretch, 3 * h.items[1].width);
    EXPECT_EQ(h.items[1].shrink, 0);
}

TEST(LineBreak, SingleLineParagraphHasDemerits100) {
    Fixture f;
    Context c = f.ctx(160000);
    c.firstIndent = 18000;
    HList h = f.build("The quick brown fox.", c);
    BreakResult r = breakIntoLines(h, f.settings);
    EXPECT_EQ(r.breaks, std::vector<int>{9});
    EXPECT_EQ(r.demerits, 100);
    EXPECT_FALSE(r.emergency);
}

TEST(LineBreak, TwoLinesMatchExample6) {
    Fixture f;
    Context c = f.ctx(160000);
    c.firstIndent = 18000;
    HList h = f.build("The quick brown fox jumps over the lazy dog.", c);
    BreakResult r = breakIntoLines(h, f.settings);
    ASSERT_EQ(r.breaks.size(), 2u);
    EXPECT_EQ(r.demerits, 3016);
    Stats stats;
    auto lines = setLines(h, r.breaks, f.fonts, stats);
    ASSERT_EQ(lines.size(), 2u);
    EXPECT_EQ(lines[0].runs[0].x, 38000);
    EXPECT_EQ(lines[0].runs[1].x, 55521);  // shrunk glue, floor distribution
    EXPECT_EQ(lines[1].runs[0].x, 20000);
}

TEST(LineBreak, ZeroToleranceFallsBackToPassTwo) {
    Fixture f;
    f.settings = Settings::parse("tolerance = 0\n");
    HList h = f.build("The quick brown fox jumps over the lazy dog and more words follow here", f.ctx(60000));
    Stats stats;
    auto lines = typesetList(h, f.settings, f.fonts, stats);
    EXPECT_EQ(stats.emergencyLists, 1);
    // pass 2 minimises demerits only, so the cheapest breaking is the fewest lines
    EXPECT_EQ(lines.size(), 1u);
    EXPECT_EQ(stats.overfullLines, 1);
}

TEST(LineBreak, OverfullWordIsPlacedAndCounted) {
    Fixture f;
    HList h = f.build("Supercalifragilistic", f.ctx(8000));
    Stats stats;
    auto lines = typesetList(h, f.settings, f.fonts, stats);
    EXPECT_GE(stats.overfullLines, 1);
    EXPECT_FALSE(lines.empty());
}

TEST(LineBreak, EmptyListIsOneEmptyLine) {
    Fixture f;
    Document d = Document::parse("@h1\n");
    HListBuilder b(f.settings, f.fonts, f.patterns);
    HList h = b.build(d.blocks[0]->text, f.ctx(100000));
    BreakResult r = breakIntoLines(h, f.settings);
    EXPECT_EQ(r.breaks.size(), 1u);
    EXPECT_EQ(r.demerits, 100);
}

TEST(HList, MeasuringIsConsistentWithPrefixSums) {
    Fixture f;
    HList h = f.build("The quick brown fox jumps", f.ctx(100000));
    auto m = h.measure(1, 3);
    EXPECT_EQ(m.width, 22240);  // "quick"; leading glue removed
    EXPECT_EQ(m.stretch, 0);
    EXPECT_EQ(h.minWidth(), 25140);  // "brown"
}
