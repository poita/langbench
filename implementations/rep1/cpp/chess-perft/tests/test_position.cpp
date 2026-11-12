#include "test_helpers.hpp"

using namespace chessperft;

namespace {
Position play(const std::string& fen, const std::string& uci) {
  Position pos = mustParse(fen);
  for (const Move m : legalMoves(pos)) {
    if (m.toUci() == uci) {
      pos.makeMove(m);
      return pos;
    }
  }
  ADD_FAILURE() << uci << " is not legal in " << fen;
  return pos;
}
}  // namespace

TEST(Position, DoublePushSetsEnPassantSquare) {
  const Position pos = play("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "e2e4");
  EXPECT_EQ(toFen(pos), "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1");
  const Position next = play(toFen(pos), "g8f6");
  EXPECT_EQ(next.enPassantSquare(), kNoSquare);
}

TEST(Position, EnPassantRemovesPawn) {
  const Position pos = play("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", "e5d6");
  EXPECT_EQ(toFen(pos), "4k3/8/3P4/8/8/8/8/4K3 b - - 0 1");
}

TEST(Position, CastlingMovesRookAndClearsRights) {
  const Position wk = play("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "e1g1");
  EXPECT_EQ(toFen(wk), "r3k2r/8/8/8/8/8/8/R4RK1 b kq - 0 1");
  const Position bq = play("r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1", "e8c8");
  EXPECT_EQ(toFen(bq), "2kr3r/8/8/8/8/8/8/R3K2R w KQ - 0 1");
}

TEST(Position, RookMoveAndRookCaptureClearRights) {
  const Position moved = play("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "h1h5");
  EXPECT_EQ(moved.castlingRights(), kWhiteQueenside | kBlackKingside | kBlackQueenside);
  const Position captured = play("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "a1a8");
  EXPECT_EQ(captured.castlingRights(), kWhiteKingside | kBlackKingside);
}

TEST(Position, PromotionCaptureOnCornerClearsRight) {
  const Position pos = play("r3k2r/1P6/8/8/8/8/8/4K3 w kq - 0 1", "b7a8q");
  EXPECT_EQ(pos.castlingRights(), kBlackKingside);
  EXPECT_EQ(pos.pieceAt(*parseSquare("a8")), Piece::WhiteQueen);
}

TEST(Position, KingMoveClearsBothRights) {
  const Position pos = play("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "e1e2");
  EXPECT_EQ(pos.castlingRights(), kBlackKingside | kBlackQueenside);
}

TEST(Position, AttackQueries) {
  const Position pos = mustParse("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1");
  EXPECT_TRUE(pos.inCheck());
  EXPECT_TRUE(pos.isAttacked(*parseSquare("e1"), Color::Black));
  EXPECT_FALSE(pos.isAttacked(*parseSquare("d1"), Color::Black));
  EXPECT_TRUE(pos.isAttacked(*parseSquare("a2"), Color::Black));
  EXPECT_FALSE(pos.isAttacked(*parseSquare("a3"), Color::Black));
}
