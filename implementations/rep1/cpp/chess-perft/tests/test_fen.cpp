#include "test_helpers.hpp"

using namespace chessperft;

constexpr const char* kStartFen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

TEST(Fen, StartPositionRoundTrips) {
  const Position pos = mustParse(kStartFen);
  EXPECT_EQ(pos, Position::startPosition());
  EXPECT_EQ(toFen(pos), kStartFen);
  EXPECT_EQ(pos.pieceAt(*parseSquare("e1")), Piece::WhiteKing);
  EXPECT_EQ(pos.pieceAt(*parseSquare("d8")), Piece::BlackQueen);
  EXPECT_EQ(pos.pieceAt(*parseSquare("e4")), Piece::None);
  EXPECT_EQ(pos.castlingRights(), kAllCastling);
  EXPECT_EQ(popcount(pos.occupied()), 32);
}

TEST(Fen, ParsesSideCastlingAndEnPassant) {
  const Position pos = mustParse("4k3/8/8/8/3Pp3/8/8/R3K2R b Kq d3 5 20");
  EXPECT_EQ(pos.sideToMove(), Color::Black);
  EXPECT_EQ(pos.castlingRights(), kWhiteKingside | kBlackQueenside);
  EXPECT_EQ(pos.enPassantSquare(), *parseSquare("d3"));
  EXPECT_EQ(toFen(pos), "4k3/8/8/8/3Pp3/8/8/R3K2R b Kq d3 0 1");
}

TEST(Fen, CountersAreOptional) {
  EXPECT_TRUE(parseFen("4k3/8/8/8/8/8/8/4K3 w - -"));
}

TEST(Fen, RejectsMalformedInput) {
  EXPECT_FALSE(parseFen(""));
  EXPECT_FALSE(parseFen("4k3/8/8/8/8/8/8/4K3 w -"));                // too few fields
  EXPECT_FALSE(parseFen("4k3/8/8/8/8/8/8/4K3 x - - 0 1"));          // bad side
  EXPECT_FALSE(parseFen("4k3/8/8/8/8/8/8/4K3 w X - 0 1"));          // bad castling
  EXPECT_FALSE(parseFen("4k3/8/8/8/8/8/8/4K3 w - e9 0 1"));         // bad ep
  EXPECT_FALSE(parseFen("4k3/8/8/8/8/8/4K3 w - - 0 1"));            // 7 ranks
  EXPECT_FALSE(parseFen("4k4/8/8/8/8/8/8/4K3 w - - 0 1"));          // 9 files
  EXPECT_FALSE(parseFen("4k3/8/8/8/8/8/8/8 w - - 0 1"));            // no white king
  EXPECT_FALSE(parseFen("4k3/8/8/8/8/8/8/4KK2 w - - 0 1"));         // two white kings
  EXPECT_FALSE(parseFen("4k3/8/8/8/8/8/8/4K3 w - - 0 1 extra"));    // too many fields
}
