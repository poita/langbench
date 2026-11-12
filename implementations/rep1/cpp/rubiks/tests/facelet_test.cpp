#include <gtest/gtest.h>

#include "rubiks/facelet.hpp"

using namespace rubiks;

namespace {
FaceletCube run(const char* moves) {
  FaceletCube c;
  c.apply(*parseMoves(moves));
  return c;
}
Face colourAt(const FaceletCube& c, const char* name) { return c.at(*faceletIndex(name)); }
}  // namespace

TEST(Facelet, NamesRoundTrip) {
  for (int i = 0; i < kFaceletCount; ++i) EXPECT_EQ(faceletIndex(faceletName(i)), i);
  EXPECT_FALSE(faceletIndex("U0"));
  EXPECT_FALSE(faceletIndex("X1"));
}

TEST(Facelet, SolvedCubeIsSolved) { EXPECT_TRUE(FaceletCube().isSolved()); }

TEST(Facelet, SpecExampleUMove) {
  FaceletCube c = run("U");
  for (const char* n : {"F1", "F2", "F3"}) EXPECT_EQ(colourAt(c, n), Face::R) << n;
  for (const char* n : {"L1", "L2", "L3"}) EXPECT_EQ(colourAt(c, n), Face::F) << n;
  for (const char* n : {"B1", "B2", "B3"}) EXPECT_EQ(colourAt(c, n), Face::L) << n;
  for (const char* n : {"R1", "R2", "R3"}) EXPECT_EQ(colourAt(c, n), Face::B) << n;
}

TEST(Facelet, QuarterTurnsHaveOrderFour) {
  for (int f = 0; f < kFaceCount; ++f) {
    FaceletCube c;
    for (int i = 0; i < 4; ++i) c.apply(Move(static_cast<Face>(f), 1));
    EXPECT_TRUE(c.isSolved());
  }
}

TEST(Facelet, InverseAndHalfTurnTokens) {
  for (int f = 0; f < kFaceCount; ++f) {
    Face face = static_cast<Face>(f);
    FaceletCube a, b;
    a.apply(Move(face, 2));
    b.apply(Move(face, 1));
    b.apply(Move(face, 1));
    EXPECT_EQ(a, b);
    a.apply(Move(face, 2));
    EXPECT_TRUE(a.isSolved());
    FaceletCube c;
    c.apply(Move(face, 1));
    c.apply(Move(face, 3));
    EXPECT_TRUE(c.isSolved());
  }
}

namespace {
int order(const char* moves) {
  FaceletCube c;
  auto seq = *parseMoves(moves);
  for (int n = 1; n < 2000; ++n) {
    c.apply(seq);
    if (c.isSolved()) return n;
  }
  return -1;
}
}  // namespace

TEST(Facelet, SpecSanityOrders) {
  EXPECT_EQ(order("R U R' U'"), 6);
  EXPECT_EQ(order("R U"), 105);
  EXPECT_EQ(order("U D"), 4);
}

TEST(Facelet, SuperflipHasAllEdgesFlipped) {
  FaceletCube c = run("U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2");
  // Corners are solved: spot-check the eight corner stickers of two corners.
  EXPECT_EQ(colourAt(c, "U9"), Face::U);
  EXPECT_EQ(colourAt(c, "R1"), Face::R);
  EXPECT_EQ(colourAt(c, "F3"), Face::F);
  // Edges are in place but flipped.
  EXPECT_EQ(colourAt(c, "U8"), Face::F);
  EXPECT_EQ(colourAt(c, "F2"), Face::U);
  EXPECT_EQ(colourAt(c, "F6"), Face::R);
  EXPECT_EQ(colourAt(c, "R4"), Face::F);
}

TEST(Facelet, StringRoundTrip) {
  FaceletCube c = run("R U F' L2 D B");
  EXPECT_EQ(FaceletCube::fromString(c.toString()), c);
  EXPECT_FALSE(FaceletCube::fromString("URF"));
  EXPECT_EQ(FaceletCube().toString().substr(0, 9), "UUUUUUUUU");
}
