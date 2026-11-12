#include <gtest/gtest.h>

#include "rubiks/move.hpp"

using namespace rubiks;

TEST(Move, ParseAllEighteenTokens) {
  const char* tokens[] = {"U", "U'", "U2", "D", "D'", "D2", "L", "L'", "L2",
                          "R", "R'", "R2", "F", "F'", "F2", "B", "B'", "B2"};
  for (const char* t : tokens) {
    auto m = parseMove(t);
    ASSERT_TRUE(m.has_value()) << t;
    EXPECT_EQ(m->str(), t);
  }
}

TEST(Move, RejectsMalformedTokens) {
  for (const char* t : {"", "r", "R3", "R2'", "R'2", "X", "RR", "'", "2"})
    EXPECT_FALSE(parseMove(t).has_value()) << t;
}

TEST(Move, FaceTurnsAndIndexRoundTrip) {
  for (int i = 0; i < kMoveCount; ++i) {
    Move m = Move::fromIndex(i);
    EXPECT_EQ(Move(m.face(), m.turns()), m);
    EXPECT_EQ(m.inverse().inverse(), m);
  }
  EXPECT_EQ(parseMove("R")->inverse(), *parseMove("R'"));
  EXPECT_EQ(parseMove("R2")->inverse(), *parseMove("R2"));
  EXPECT_TRUE(parseMove("F2")->isHalfTurn());
}

TEST(Move, SequenceParsingAndFormatting) {
  auto seq = parseMoves("R U R' U'");
  ASSERT_TRUE(seq);
  EXPECT_EQ(seq->size(), 4u);
  EXPECT_EQ(toString(*seq), "R U R' U'");
  EXPECT_EQ(toString(inverse(*seq)), "U R U' R'");
  EXPECT_TRUE(parseMoves("")->empty());
  EXPECT_FALSE(parseMoves("R U Q").has_value());
}
