#include <gtest/gtest.h>

#include "textbuffer/movement.hpp"

using namespace textbuffer;

namespace {

Cursor at(std::uint32_t l, std::uint32_t c, std::uint32_t goal = 0) {
    Cursor x;
    x.head = {l, c};
    x.goal = goal;
    x.primary = true;
    return x;
}

const Document kDoc = Document::fromText("hello\n\nabc");

}  // namespace

TEST(Movement, LeftRightWrapAcrossLines) {
    EXPECT_EQ(moveCursor(at(1, 0), kDoc, Direction::Left, false).head, (Position{0, 5}));
    EXPECT_EQ(moveCursor(at(0, 5), kDoc, Direction::Right, false).head, (Position{1, 0}));
    EXPECT_EQ(moveCursor(at(0, 0), kDoc, Direction::Left, false).head, (Position{0, 0}));
    EXPECT_EQ(moveCursor(at(2, 3), kDoc, Direction::Right, false).head, (Position{2, 3}));
}

TEST(Movement, HomeEnd) {
    EXPECT_EQ(moveCursor(at(0, 2), kDoc, Direction::Home, false).head, (Position{0, 0}));
    EXPECT_EQ(moveCursor(at(0, 2), kDoc, Direction::End, false).head, (Position{0, 5}));
}

TEST(Movement, VerticalUsesGoalColumn) {
    Cursor c = moveCursor(at(0, 4, 4), kDoc, Direction::Down, false);
    EXPECT_EQ(c.head, (Position{1, 0}));
    EXPECT_EQ(c.goal, 4u);
    c = moveCursor(c, kDoc, Direction::Down, false);
    EXPECT_EQ(c.head, (Position{2, 3}));
}

TEST(Movement, VerticalAtDocumentEdges) {
    Cursor up = moveCursor(at(0, 3, 3), kDoc, Direction::Up, false);
    EXPECT_EQ(up.head, (Position{0, 0}));
    EXPECT_EQ(up.goal, 0u);
    Cursor down = moveCursor(at(2, 1, 1), kDoc, Direction::Down, false);
    EXPECT_EQ(down.head, (Position{2, 3}));
    EXPECT_EQ(down.goal, 3u);
}

TEST(Movement, SelectStartsAndExtendsSelection) {
    Cursor c = moveCursor(at(0, 1), kDoc, Direction::Right, true);
    ASSERT_TRUE(c.hasSelection());
    EXPECT_EQ(*c.anchor, (Position{0, 1}));
    EXPECT_EQ(c.head, (Position{0, 2}));
    c = moveCursor(c, kDoc, Direction::Left, true);
    EXPECT_FALSE(c.hasSelection());
}

TEST(Movement, CollapseSelectionWithLeftRight) {
    Cursor c;
    c.head = {0, 4};
    c.anchor = Position{0, 1};
    EXPECT_EQ(moveCursor(c, kDoc, Direction::Left, false).head, (Position{0, 1}));
    EXPECT_EQ(moveCursor(c, kDoc, Direction::Right, false).head, (Position{0, 4}));
    EXPECT_FALSE(moveCursor(c, kDoc, Direction::Left, false).hasSelection());
    // Other directions drop the selection and move from the head.
    EXPECT_EQ(moveCursor(c, kDoc, Direction::Home, false).head, (Position{0, 0}));
}
