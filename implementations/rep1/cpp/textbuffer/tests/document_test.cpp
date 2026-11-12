#include <gtest/gtest.h>

#include "textbuffer/document.hpp"

using namespace textbuffer;

TEST(Position, OrdersByLineThenColumn) {
    EXPECT_LT((Position{0, 9}), (Position{1, 0}));
    EXPECT_LT((Position{2, 1}), (Position{2, 2}));
    EXPECT_EQ((Position{3, 3}), (Position{3, 3}));
}

TEST(Position, AdvanceOverText) {
    EXPECT_EQ(advance({2, 3}, "abc"), (Position{2, 6}));
    EXPECT_EQ(advance({2, 3}, "a\nbc"), (Position{3, 2}));
    EXPECT_EQ(advance({2, 3}, "a\n"), (Position{3, 0}));
    EXPECT_EQ(advance({2, 3}, "\n\n"), (Position{4, 0}));
    EXPECT_EQ(advance({2, 3}, ""), (Position{2, 3}));
}

TEST(Document, DefaultIsOneEmptyLine) {
    Document d;
    EXPECT_EQ(d.lineCount(), 1u);
    EXPECT_EQ(d.text(), "");
    EXPECT_EQ(Document(std::vector<std::string>{}).lineCount(), 1u);
}

TEST(Document, FromTextAndBack) {
    auto d = Document::fromText("ab\n\ncd");
    ASSERT_EQ(d.lineCount(), 3u);
    EXPECT_EQ(d.line(1), "");
    EXPECT_EQ(d.text(), "ab\n\ncd");
    EXPECT_EQ(d.endPosition(), (Position{2, 2}));
    EXPECT_EQ(Document::fromText("x\n").lineCount(), 2u);
}

TEST(Document, ClampLineThenColumn) {
    auto d = Document::fromText("abc\nde");
    EXPECT_EQ(d.clamp(0, 99), (Position{0, 3}));
    EXPECT_EQ(d.clamp(99, 99), (Position{1, 2}));
    EXPECT_EQ(d.clamp(1, 1), (Position{1, 1}));
    EXPECT_EQ(d.clamp(1000000000, 1000000000), (Position{1, 2}));
}

TEST(Document, TextBetween) {
    auto d = Document::fromText("abc\ndef\nghi");
    EXPECT_EQ(d.textBetween({0, 1}, {0, 3}), "bc");
    EXPECT_EQ(d.textBetween({0, 1}, {2, 1}), "bc\ndef\ng");
    EXPECT_EQ(d.textBetween({1, 3}, {2, 0}), "\n");
    EXPECT_EQ(d.textBetween({1, 1}, {1, 1}), "");
}

TEST(Document, ReplaceWithinLine) {
    auto d = Document::fromText("hello world");
    d.replace({0, 5}, {0, 6}, ", ");
    EXPECT_EQ(d.text(), "hello, world");
    d.replace({0, 0}, {0, 5}, "");
    EXPECT_EQ(d.text(), ", world");
}

TEST(Document, ReplaceSplitsLines) {
    auto d = Document::fromText("abcd");
    d.replace({0, 2}, {0, 2}, "X\nY\nZ");
    EXPECT_EQ(d.text(), "abX\nY\nZcd");
    EXPECT_EQ(d.lineCount(), 3u);
}

TEST(Document, ReplaceJoinsLines) {
    auto d = Document::fromText("abc\ndef\nghi\njkl");
    d.replace({0, 2}, {2, 1}, "");
    EXPECT_EQ(d.text(), "abhi\njkl");
    d.replace({0, 4}, {1, 0}, "");
    EXPECT_EQ(d.text(), "abhijkl");
}

TEST(Document, ReplaceMultiLineWithMultiLine) {
    auto d = Document::fromText("a\nb\nc\nd");
    d.replace({0, 1}, {3, 0}, "1\n2");
    EXPECT_EQ(d.text(), "a1\n2d");
    d.replace({0, 0}, {1, 1}, "x\ny\nz\n");
    EXPECT_EQ(d.text(), "x\ny\nz\nd");
    d.replace({3, 1}, {3, 1}, "\n");
    EXPECT_EQ(d.text(), "x\ny\nz\nd\n");
}
