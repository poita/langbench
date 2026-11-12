#include <gtest/gtest.h>

#include <sstream>

#include "textbuffer/editor.hpp"

using namespace textbuffer;

namespace {

Editor make(std::string_view text) { return Editor(Document::fromText(text)); }

std::vector<Position> heads(const Editor& e) {
    std::vector<Position> v;
    for (const auto& c : e.cursors()) v.push_back(c.head);
    return v;
}

using Ps = std::vector<Position>;

}  // namespace

TEST(Editor, InitialState) {
    Editor e;
    ASSERT_EQ(e.cursors().size(), 1u);
    EXPECT_TRUE(e.cursors()[0].primary);
    EXPECT_EQ(e.cursors()[0].head, (Position{0, 0}));
    EXPECT_EQ(e.undoDepth(), 0u);
}

TEST(Editor, InsertAndBackspace) {
    auto e = make("abc");
    e.move(Direction::End);
    e.insert("d\ne");
    EXPECT_EQ(e.document().text(), "abcd\ne");
    EXPECT_EQ(heads(e), (Ps{{1, 1}}));
    e.deleteBackward();
    EXPECT_EQ(e.document().text(), "abcd\n");
    e.deleteBackward();
    EXPECT_EQ(e.document().text(), "abcd");
    EXPECT_EQ(heads(e), (Ps{{0, 4}}));
    e.deleteBackward();
    EXPECT_EQ(e.document().text(), "abc");
}

TEST(Editor, DeleteAtBoundariesDoesNothingAndRecordsNothing) {
    auto e = make("ab");
    e.deleteBackward();
    EXPECT_EQ(e.undoDepth(), 0u);
    e.move(Direction::End);
    e.deleteForward();
    EXPECT_EQ(e.undoDepth(), 0u);
    EXPECT_EQ(e.document().text(), "ab");
}

TEST(Editor, DeleteForwardJoinsLines) {
    auto e = make("ab\ncd");
    e.move(Direction::End);
    e.deleteForward();
    EXPECT_EQ(e.document().text(), "abcd");
    EXPECT_EQ(heads(e), (Ps{{0, 2}}));
}

TEST(Editor, MultiCursorInsertShiftsLaterCursors) {
    auto e = make("alpha\nbeta\ngamma");
    e.addCursor(1, 0);
    e.addCursor(2, 0);
    e.insert("- ");
    EXPECT_EQ(e.document().text(), "- alpha\n- beta\n- gamma");
    EXPECT_EQ(heads(e), (Ps{{0, 2}, {1, 2}, {2, 2}}));
}

TEST(Editor, MultiCursorSameLineAndNewlines) {
    auto e = make("abcdef");
    e.goTo(0, 1);
    e.addCursor(0, 4);
    e.insert("\n");
    EXPECT_EQ(e.document().text(), "a\nbcd\nef");
    EXPECT_EQ(heads(e), (Ps{{1, 0}, {2, 0}}));
}

TEST(Editor, AdjacentBackspacesMerge) {
    auto e = make("abcdef");
    e.goTo(0, 3);
    e.addCursor(0, 4);
    e.deleteBackward();
    EXPECT_EQ(e.document().text(), "abef");
    EXPECT_EQ(heads(e), (Ps{{0, 2}}));
}

TEST(Editor, AdjacentDeleteForwardMerge) {
    auto e = make("abcdef");
    e.goTo(0, 2);
    e.addCursor(0, 3);
    e.deleteForward();
    EXPECT_EQ(e.document().text(), "abef");
    EXPECT_EQ(heads(e), (Ps{{0, 2}}));
}

TEST(Editor, DeleteForwardAcrossLinesWithManyCursors) {
    auto e = make("a\nb\nc\nd");
    e.addCursor(0, 1);  // cursors at (0,0), (0,1), (1,1), (2,1)
    e.addCursor(1, 1);
    e.addCursor(2, 1);
    e.deleteForward();
    EXPECT_EQ(e.document().text(), "bcd");
    EXPECT_EQ(heads(e), (Ps{{0, 0}, {0, 1}, {0, 2}}));
}

TEST(Editor, SelectionReplaced) {
    auto e = make("hello world");
    e.move(Direction::Right, true);
    e.move(Direction::Right, true);
    e.insert("J");
    EXPECT_EQ(e.document().text(), "Jllo world");
    EXPECT_EQ(heads(e), (Ps{{0, 1}}));
    EXPECT_FALSE(e.cursors()[0].hasSelection());
}

TEST(Editor, GoalColumnSurvivesVerticalMoves) {
    auto e = make("abcdef\nx\nabcdef");
    e.goTo(0, 5);
    e.move(Direction::Down);
    EXPECT_EQ(heads(e), (Ps{{1, 1}}));
    e.move(Direction::Down);
    EXPECT_EQ(heads(e), (Ps{{2, 5}}));
    e.move(Direction::Left);
    e.move(Direction::Up);
    e.move(Direction::Up);
    EXPECT_EQ(heads(e), (Ps{{0, 4}}));
}

TEST(Editor, MoveMergesCursors) {
    auto e = make("ab\nc");
    e.goTo(0, 2);
    e.addCursor(1, 0);
    e.move(Direction::Right);  // (0,2) -> (1,0), (1,0) -> (1,1)
    EXPECT_EQ(heads(e), (Ps{{1, 0}, {1, 1}}));
    e.move(Direction::Home);
    EXPECT_EQ(heads(e), (Ps{{1, 0}}));
    EXPECT_TRUE(e.cursors()[0].primary);
}

TEST(Editor, ClearCursorsKeepsPrimarySelection) {
    auto e = make("abcdef");
    e.goTo(0, 1);
    e.move(Direction::Right, true);
    e.addCursor(0, 5);
    e.clearCursors();
    ASSERT_EQ(e.cursors().size(), 1u);
    EXPECT_TRUE(e.cursors()[0].hasSelection());
}

TEST(Editor, UndoRedoSpecExample) {
    auto e = make("abc");
    e.move(Direction::End);
    e.insert("d\ne");
    e.deleteBackward();
    e.deleteBackward();
    EXPECT_TRUE(e.undo());
    EXPECT_EQ(e.document().text(), "abcd\n");
    EXPECT_EQ(heads(e), (Ps{{1, 0}}));
    EXPECT_TRUE(e.undo());
    EXPECT_EQ(e.document().text(), "abcd\ne");
    EXPECT_TRUE(e.redo());
    EXPECT_EQ(e.document().text(), "abcd\n");
    e.insert("Z");
    EXPECT_FALSE(e.redo());
    EXPECT_EQ(e.document().text(), "abcd\nZ");
}

TEST(Editor, UndoRestoresSelectionsAndPrimary) {
    auto e = make("one\ntwo\nthree");
    e.addCursor(1, 0);
    e.move(Direction::End, true);
    const auto before = e.cursors();
    e.insert("X\nY");
    EXPECT_TRUE(e.undo());
    EXPECT_EQ(e.document().text(), "one\ntwo\nthree");
    EXPECT_EQ(e.cursors(), before);
    const auto afterCursors = [&] {
        e.redo();
        return e.cursors();
    }();
    EXPECT_EQ(e.document().text(), "X\nY\nX\nY\nthree");
    EXPECT_EQ(afterCursors.size(), 2u);
}

TEST(Editor, UndoOfMultiCursorEditIsOneStep) {
    auto e = make("a\nb\nc");
    e.addCursor(1, 0);
    e.addCursor(2, 0);
    e.insert("x");
    e.insert("y");
    e.undo();
    EXPECT_EQ(e.document().text(), "xa\nxb\nxc");
    e.undo();
    EXPECT_EQ(e.document().text(), "a\nb\nc");
    EXPECT_FALSE(e.undo());
}

TEST(Editor, GoalColumnsResetByUndo) {
    auto e = make("abcdef\nx");
    e.goTo(0, 5);
    e.insert("!");
    e.move(Direction::Down);   // keeps goal 6
    e.undo();                  // restores (0,5); resets goal to 5
    e.move(Direction::Down);
    e.move(Direction::Up);
    EXPECT_EQ(heads(e), (Ps{{0, 5}}));
}

TEST(Editor, PrintFormat) {
    auto e = make("ab\n\ncd");
    e.addCursor(2, 1);
    std::ostringstream out;
    e.print(out);
    EXPECT_EQ(out.str(), "ab\n\ncd\ncursor 0 0\ncursor 2 1\n--\n");
}
