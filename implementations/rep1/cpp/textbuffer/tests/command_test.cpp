#include <gtest/gtest.h>

#include "textbuffer/command.hpp"

using namespace textbuffer;

TEST(DecodeInsertText, Escapes) {
    EXPECT_EQ(decodeInsertText("a\\nb"), "a\nb");
    EXPECT_EQ(decodeInsertText("a\\\\nb"), "a\\nb");
    EXPECT_EQ(decodeInsertText("  x  "), "  x  ");
    EXPECT_EQ(decodeInsertText("\\\\"), "\\");
}

TEST(ParseCommand, Insert) {
    auto c = parseCommand("insert  hi \\n");
    ASSERT_TRUE(c);
    EXPECT_EQ(c->kind, Command::Kind::Insert);
    EXPECT_EQ(c->text, " hi \n");
    EXPECT_FALSE(parseCommand("insert"));
    EXPECT_FALSE(parseCommand("insert "));
}

TEST(ParseCommand, Move) {
    auto c = parseCommand("move up select");
    ASSERT_TRUE(c);
    EXPECT_EQ(c->kind, Command::Kind::Move);
    EXPECT_EQ(c->direction, Direction::Up);
    EXPECT_TRUE(c->select);
    c = parseCommand("move home");
    ASSERT_TRUE(c);
    EXPECT_EQ(c->direction, Direction::Home);
    EXPECT_FALSE(c->select);
    EXPECT_FALSE(parseCommand("move sideways"));
    EXPECT_FALSE(parseCommand("move"));
}

TEST(ParseCommand, PositionCommands) {
    auto g = parseCommand("goto 12 1000000000");
    ASSERT_TRUE(g);
    EXPECT_EQ(g->kind, Command::Kind::Goto);
    EXPECT_EQ(g->line, 12u);
    EXPECT_EQ(g->col, 1000000000u);
    auto a = parseCommand("add-cursor 0 3");
    ASSERT_TRUE(a);
    EXPECT_EQ(a->kind, Command::Kind::AddCursor);
    EXPECT_FALSE(parseCommand("goto 1"));
    EXPECT_FALSE(parseCommand("goto a b"));
}

TEST(ParseCommand, Simple) {
    EXPECT_EQ(parseCommand("delete")->kind, Command::Kind::Delete);
    EXPECT_EQ(parseCommand("delete-forward")->kind, Command::Kind::DeleteForward);
    EXPECT_EQ(parseCommand("clear-cursors")->kind, Command::Kind::ClearCursors);
    EXPECT_EQ(parseCommand("undo")->kind, Command::Kind::Undo);
    EXPECT_EQ(parseCommand("redo")->kind, Command::Kind::Redo);
    EXPECT_EQ(parseCommand("print")->kind, Command::Kind::Print);
    EXPECT_FALSE(parseCommand("frobnicate"));
    EXPECT_FALSE(parseCommand("undo now"));
}
