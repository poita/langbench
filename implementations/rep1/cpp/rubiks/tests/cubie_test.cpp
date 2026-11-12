#include <gtest/gtest.h>

#include <random>

#include "rubiks/cubie.hpp"

using namespace rubiks;

namespace {
std::vector<Move> randomMoves(std::mt19937& rng, int n) {
  std::vector<Move> v;
  for (int i = 0; i < n; ++i) v.push_back(Move::fromIndex(rng() % kMoveCount));
  return v;
}
}  // namespace

TEST(Cubie, SolvedIsValidAndSolved) {
  CubieCube c;
  EXPECT_TRUE(c.isSolved());
  EXPECT_TRUE(c.isValid());
}

TEST(Cubie, AgreesWithFaceletModelOnRandomScrambles) {
  std::mt19937 rng(12345);
  for (int t = 0; t < 200; ++t) {
    auto seq = randomMoves(rng, 1 + rng() % 60);
    FaceletCube f;
    CubieCube c;
    f.apply(seq);
    c.apply(seq);
    EXPECT_EQ(c.toFacelets(), f);
    EXPECT_EQ(CubieCube::fromFacelets(f), c);
    EXPECT_TRUE(c.isValid());
  }
}

TEST(Cubie, MoveFollowedByInverseIsIdentity) {
  for (int i = 0; i < kMoveCount; ++i) {
    CubieCube c;
    c.apply(Move::fromIndex(i));
    EXPECT_EQ(c.isSolved(), false);
    c.apply(Move::fromIndex(i).inverse());
    EXPECT_TRUE(c.isSolved());
  }
}

TEST(Cubie, OnlyFBQuarterTurnsFlipEdges) {
  for (int i = 0; i < kMoveCount; ++i) {
    Move m = Move::fromIndex(i);
    CubieCube c;
    c.apply(m);
    int flips = 0;
    for (auto v : c.eo) flips += v;
    bool fbQuarter = (m.face() == Face::F || m.face() == Face::B) && !m.isHalfTurn();
    EXPECT_EQ(flips, fbQuarter ? 4 : 0) << m.str();
  }
}

TEST(Cubie, DetectsInvalidStates) {
  CubieCube c;
  c.co[0] = 1;  // single twisted corner
  EXPECT_FALSE(c.isValid());
  CubieCube e;
  e.eo[3] = 1;  // single flipped edge
  EXPECT_FALSE(e.isValid());
  CubieCube p;
  std::swap(p.ep[0], p.ep[1]);  // lone edge swap: parity mismatch
  EXPECT_FALSE(p.isValid());
  CubieCube d;
  d.cp[1] = 0;  // not a permutation
  EXPECT_FALSE(d.isValid());
}
