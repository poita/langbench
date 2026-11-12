#include "test_helpers.hpp"

using namespace chessperft;

TEST(Types, SquareNames) {
  EXPECT_EQ(squareName(0), "a1");
  EXPECT_EQ(squareName(63), "h8");
  EXPECT_EQ(squareName(kNoSquare), "-");
  EXPECT_EQ(parseSquare("e4"), makeSquare(4, 3));
  EXPECT_FALSE(parseSquare("i1"));
  EXPECT_FALSE(parseSquare("a9"));
  EXPECT_FALSE(parseSquare("a"));
}

TEST(Types, PieceEncoding) {
  EXPECT_EQ(typeOf(Piece::BlackQueen), PieceType::Queen);
  EXPECT_EQ(colorOf(Piece::BlackQueen), Color::Black);
  EXPECT_EQ(makePiece(Color::White, PieceType::King), Piece::WhiteKing);
  EXPECT_EQ(~Color::White, Color::Black);
}

TEST(Types, BitHelpers) {
  Bitboard b = bit(3) | bit(17) | bit(60);
  EXPECT_EQ(popcount(b), 3);
  EXPECT_EQ(lsb(b), 3);
  EXPECT_EQ(msb(b), 60);
  EXPECT_EQ(popLsb(b), 3);
  EXPECT_EQ(b, bit(17) | bit(60));
}

TEST(Attacks, Knight) {
  EXPECT_EQ(popcount(knightAttacks(*parseSquare("e4"))), 8);
  EXPECT_EQ(knightAttacks(*parseSquare("a1")), bit(*parseSquare("b3")) | bit(*parseSquare("c2")));
}

TEST(Attacks, KingAndPawn) {
  EXPECT_EQ(popcount(kingAttacks(*parseSquare("h8"))), 3);
  EXPECT_EQ(popcount(kingAttacks(*parseSquare("d4"))), 8);
  EXPECT_EQ(pawnAttacks(Color::White, *parseSquare("e2")),
            bit(*parseSquare("d3")) | bit(*parseSquare("f3")));
  EXPECT_EQ(pawnAttacks(Color::Black, *parseSquare("a7")), bit(*parseSquare("b6")));
}

TEST(Attacks, SlidersStopAtBlockers) {
  const Square d4 = *parseSquare("d4");
  EXPECT_EQ(popcount(rookAttacks(d4, 0)), 14);
  EXPECT_EQ(popcount(bishopAttacks(d4, 0)), 13);
  EXPECT_EQ(popcount(queenAttacks(d4, 0)), 27);
  const Bitboard occ = bit(*parseSquare("d6")) | bit(*parseSquare("b4")) |
                       bit(*parseSquare("f6")) | bit(*parseSquare("c3"));
  const Bitboard rook = rookAttacks(d4, occ);
  EXPECT_TRUE(rook & bit(*parseSquare("d6")));   // blocker included
  EXPECT_FALSE(rook & bit(*parseSquare("d7")));  // beyond blocker excluded
  EXPECT_TRUE(rook & bit(*parseSquare("b4")));
  EXPECT_FALSE(rook & bit(*parseSquare("a4")));
  const Bitboard bishop = bishopAttacks(d4, occ);
  EXPECT_TRUE(bishop & bit(*parseSquare("c3")));
  EXPECT_FALSE(bishop & bit(*parseSquare("b2")));
  EXPECT_TRUE(bishop & bit(*parseSquare("f6")));
  EXPECT_FALSE(bishop & bit(*parseSquare("g7")));
}

TEST(Attacks, BetweenAndLine) {
  const Square a1 = *parseSquare("a1"), d4 = *parseSquare("d4"), h8 = *parseSquare("h8");
  EXPECT_EQ(between(a1, d4), bit(*parseSquare("b2")) | bit(*parseSquare("c3")));
  EXPECT_EQ(between(d4, a1), between(a1, d4));
  EXPECT_EQ(between(a1, *parseSquare("b3")), 0);
  EXPECT_EQ(between(a1, *parseSquare("b2")), 0);
  EXPECT_EQ(line(a1, d4), line(d4, h8));
  EXPECT_EQ(popcount(line(a1, d4)), 8);
  EXPECT_EQ(line(a1, *parseSquare("b3")), 0);
  EXPECT_EQ(popcount(line(*parseSquare("e2"), *parseSquare("e7"))), 8);
}
