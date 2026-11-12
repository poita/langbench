#include <gtest/gtest.h>

#include "spiremark/script.hpp"

using namespace spiremark;

TEST(Script, SplitLinesStripsCarriageReturns) {
    auto lines = split_lines("a\r\nb\n\nc");
    ASSERT_EQ(lines.size(), 4u);
    EXPECT_EQ(lines[0], "a");
    EXPECT_EQ(lines[2], "");
    EXPECT_EQ(lines[3], "c");
}

TEST(Script, CommentDetection) {
    EXPECT_TRUE(is_comment_line(""));
    EXPECT_TRUE(is_comment_line("   \t"));
    EXPECT_TRUE(is_comment_line("  # hi"));
    EXPECT_FALSE(is_comment_line("A PASS"));
}

TEST(Script, ParsesActions) {
    ScriptLine l = parse_script_line("A PLAY 02 #007 B ~3");
    ASSERT_EQ(l.kind, ScriptLine::Kind::Action);
    EXPECT_EQ(l.action.type, ActionType::Play);
    EXPECT_EQ(l.action.player, 0);
    EXPECT_EQ(l.action.pos, 2u);
    ASSERT_EQ(l.action.targets.size(), 3u);
    EXPECT_EQ(l.action.targets[0], Ref::object(7));
    EXPECT_EQ(l.action.targets[1], Ref::player(1));
    EXPECT_EQ(l.action.targets[2], Ref::entry(3));

    l = parse_script_line("B BLOCK #4:#2 #5:#2");
    ASSERT_EQ(l.kind, ScriptLine::Kind::Action);
    ASSERT_EQ(l.action.blocks.size(), 2u);
    EXPECT_EQ(l.action.blocks[1].first, 5u);

    l = parse_script_line("A ACT #9 2 #1");
    ASSERT_EQ(l.kind, ScriptLine::Kind::Action);
    EXPECT_EQ(l.action.index, 2u);
}

TEST(Script, ParsesDirectives) {
    EXPECT_EQ(parse_script_line("DUMP").directive, DirectiveType::Dump);
    ScriptLine c = parse_script_line("CARD CIN-001");
    EXPECT_EQ(c.kind, ScriptLine::Kind::Directive);
    EXPECT_EQ(c.card_id, "CIN-001");
}

TEST(Script, BadSyntaxCases) {
    for (const char* bad : {"X PASS", "A", "A JUMP", "A PASS now", "A PLAY", "A PLAY x",
                            "A PLAY 1 #", "A PLAY 99999999999999999999", "A BLOCK #1",
                            "A BLOCK 1:2", "A ATTACK 5", "DUMP x", "CARD", "CARD a b", "a PASS"}) {
        EXPECT_EQ(parse_script_line(bad).kind, ScriptLine::Kind::BadSyntax) << bad;
    }
}

namespace {
std::vector<std::string> L(std::initializer_list<const char*> v) { return {v.begin(), v.end()}; }
}  // namespace

TEST(Setup, ParsesDefaultsAndLists) {
    std::size_t start = 0;
    MatchSetup m = parse_setup(L({"CARDS data/cards.spire", "# c", "SEED 5", "DECK A X-1*3 Y-2",
                                  "HAND B Z-3", "START", "A PASS"}), start);
    EXPECT_EQ(start, 5u);
    EXPECT_EQ(m.spire, 25);
    EXPECT_EQ(m.opening, 5);
    EXPECT_TRUE(m.shuffle);
    ASSERT_EQ(m.zones[0][0].size(), 2u);
    EXPECT_EQ(m.zones[0][0][0].count, 3);
    EXPECT_EQ(m.zones[1][1][0].card_id, "Z-3");
}

TEST(Setup, RejectsViolations) {
    std::size_t start = 0;
    EXPECT_THROW(parse_setup(L({"SEED 1", "START"}), start), SetupError);
    EXPECT_THROW(parse_setup(L({"CARDS x", "SEED 1"}), start), SetupError);
    EXPECT_THROW(parse_setup(L({"CARDS x", "SEED 1", "SEED 2", "START"}), start), SetupError);
    EXPECT_THROW(parse_setup(L({"CARDS x", "SEED -1", "START"}), start), SetupError);
    EXPECT_THROW(parse_setup(L({"CARDS x", "SEED 1", "SPIRE 0", "START"}), start), SetupError);
    EXPECT_THROW(parse_setup(L({"CARDS x", "SEED 1", "DECK A X*0", "START"}), start), SetupError);
    EXPECT_THROW(parse_setup(L({"CARDS x", "SEED 1", "DECK A X*1001", "START"}), start), SetupError);
    EXPECT_THROW(parse_setup(L({"CARDS x", "SEED 1", "WHAT 1", "START"}), start), SetupError);
    EXPECT_THROW(parse_setup(L({"CARDS x", "SEED 1", "START now"}), start), SetupError);
}

TEST(Setup, CapLinesAreSeparatelySingleUse) {
    std::size_t start = 0;
    EXPECT_NO_THROW(parse_setup(L({"CARDS x", "SEED 1", "CAP A 1", "CAP B 2", "START"}), start));
    EXPECT_THROW(parse_setup(L({"CARDS x", "SEED 1", "CAP A 1", "CAP A 2", "START"}), start), SetupError);
}
