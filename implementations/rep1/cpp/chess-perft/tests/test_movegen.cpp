#include "test_helpers.hpp"

using namespace chessperft;

TEST(MoveGen, StartPositionHasTwentyMoves) {
  EXPECT_EQ(legalMoves(Position::startPosition()).size(), 20u);
}

TEST(MoveGen, PromotionsGenerateFourMoves) {
  const auto moves = uciMoves("8/P1k5/K7/8/8/8/8/8 w - - 0 1");
  EXPECT_EQ(moves, (std::vector<std::string>{"a6a5", "a6b5", "a7a8b", "a7a8n", "a7a8q", "a7a8r"}));
}

TEST(MoveGen, CheckmateAndStalemateHaveNoMoves) {
  EXPECT_TRUE(uciMoves("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1").empty());          // stalemate
  EXPECT_TRUE(uciMoves("R5k1/5ppp/8/8/8/8/8/6K1 b - - 0 1").empty());       // back-rank mate
}

TEST(MoveGen, KingCannotRetreatAlongCheckingLine) {
  // Rook on e8 checks e1; e2 is attacked "behind" the king along the file.
  const auto moves = uciMoves("4r1k1/8/8/8/8/8/8/4K3 w - - 0 1");
  EXPECT_EQ(moves, (std::vector<std::string>{"e1d1", "e1d2", "e1f1", "e1f2"}));
}

TEST(MoveGen, DoubleCheckAllowsOnlyKingMoves) {
  // Knight f3 and rook e8 both check the king on e1; white could capture or
  // block with other pieces only if it were a single check.
  const auto moves = uciMoves("4r1k1/8/8/8/8/5n2/8/R3K2B w - - 0 1");
  for (const auto& m : moves) EXPECT_EQ(m.substr(0, 2), "e1") << m;
  EXPECT_FALSE(moves.empty());
}

TEST(MoveGen, SingleCheckAllowsCaptureOrBlock) {
  // Rook e8 checks the king on e1; the bishop on c3 can block on e5 but not on d4.
  const auto moves = uciMoves("4r1k1/8/8/8/8/2B5/8/4K3 w - - 0 1");
  EXPECT_TRUE(std::count(moves.begin(), moves.end(), "c3e5"));
  EXPECT_FALSE(std::count(moves.begin(), moves.end(), "c3d4"));
}

TEST(MoveGen, PinnedPieceMovesOnlyAlongPin) {
  // Bishop e2 pinned along the e-file by the rook on e8 cannot move at all;
  // rook e2 pinned the same way may slide along the file.
  EXPECT_FALSE(hasMove("4r1k1/8/8/8/8/8/4B3/4K3 w - - 0 1", "e2d3"));
  const auto moves = uciMoves("4r1k1/8/8/8/8/8/4R3/4K3 w - - 0 1");
  EXPECT_TRUE(std::count(moves.begin(), moves.end(), "e2e8"));
  EXPECT_TRUE(std::count(moves.begin(), moves.end(), "e2e5"));
  EXPECT_FALSE(std::count(moves.begin(), moves.end(), "e2d2"));
}

TEST(MoveGen, PinnedPawnRestrictions) {
  // Pawn on e2 pinned on the file may push; pawn pinned diagonally may only capture the pinner.
  EXPECT_TRUE(hasMove("4r1k1/8/8/8/8/8/4P3/4K3 w - - 0 1", "e2e4"));
  EXPECT_FALSE(hasMove("7k/8/8/8/8/2b5/3P4/4K3 w - - 0 1", "d2d3"));
  EXPECT_TRUE(hasMove("7k/8/8/8/8/2b5/3P4/4K3 w - - 0 1", "d2c3"));
}

TEST(MoveGen, EnPassantBasics) {
  EXPECT_TRUE(hasMove("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", "e5d6"));
  // The ep square without a capturing pawn is harmless.
  EXPECT_EQ(legalMoves(mustParse("4k3/8/8/3p4/8/8/8/4K3 w - d6 0 1")).size(), 5u);
}

TEST(MoveGen, EnPassantIllegalWhenItExposesKingAlongRank) {
  EXPECT_FALSE(hasMove("8/8/8/KPp4r/8/8/8/7k w - c6 0 1", "b5c6"));
  EXPECT_TRUE(hasMove("8/8/8/KPp5/8/8/8/7k w - c6 0 1", "b5c6"));
}

TEST(MoveGen, EnPassantCanCaptureCheckingPawn) {
  // The white pawn on d4 (just advanced) checks the black king on e5; the
  // black pawn on c4 resolves the check by capturing it en passant.
  EXPECT_TRUE(hasMove("8/8/8/4k3/2pP4/8/8/4K3 b - d3 0 1", "c4d3"));
}

TEST(MoveGen, EnPassantIllegalWhenPinnedDiagonally) {
  // The pawn on d5 is pinned to the king on a2 by the bishop on g8; capturing
  // en passant on c6 would leave the pin line.
  EXPECT_FALSE(hasMove("6b1/8/8/2pP4/8/8/K7/7k w - c6 0 1", "d5c6"));
  EXPECT_FALSE(hasMove("6b1/8/8/2pP4/8/8/K7/7k w - c6 0 1", "d5d6"));
}

TEST(MoveGen, CastlingRequiresEmptyUnattackedPath) {
  const std::string base = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1";
  EXPECT_TRUE(hasMove(base, "e1g1"));
  EXPECT_TRUE(hasMove(base, "e1c1"));
  // Blocked path.
  EXPECT_FALSE(hasMove("r3k2r/8/8/8/8/8/8/RN2K2R w KQkq - 0 1", "e1c1"));
  EXPECT_TRUE(hasMove("r3k2r/8/8/8/8/8/8/RN2K2R w KQkq - 0 1", "e1g1"));
  // Rights missing.
  EXPECT_FALSE(hasMove("r3k2r/8/8/8/8/8/8/R3K2R w Qkq - 0 1", "e1g1"));
  // Crossing an attacked square (f1 attacked by black rook on f8).
  EXPECT_FALSE(hasMove("4kr2/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1g1"));
  // Landing square attacked.
  EXPECT_FALSE(hasMove("4k1r1/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1g1"));
  // Currently in check.
  EXPECT_FALSE(hasMove("4k3/8/8/8/8/8/4r3/R3K2R w KQ - 0 1", "e1g1"));
  EXPECT_FALSE(hasMove("4k3/8/8/8/8/8/4r3/R3K2R w KQ - 0 1", "e1c1"));
  // b1 may be attacked and the rook may be attacked.
  EXPECT_TRUE(hasMove("1r2k3/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1c1"));
  EXPECT_TRUE(hasMove("r3k3/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1c1"));
}

TEST(MoveGen, MaximumMoveCountFits) {
  // 218 legal moves, the known maximum.
  EXPECT_EQ(legalMoves(mustParse("R6R/3Q4/1Q4Q1/4Q3/2Q4Q/Q4Q2/pp1Q4/kBNN1KB1 w - - 0 1")).size(), 218u);
}
