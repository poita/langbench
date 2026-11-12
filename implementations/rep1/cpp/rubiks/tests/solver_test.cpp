#include <gtest/gtest.h>

#include <random>

#include "rubiks/rubiks.hpp"

using namespace rubiks;

namespace {

const Solver& solver() {
  static const Solver s;
  return s;
}

// Independent check at sticker level: scramble + solution gives a solved cube.
void expectSolves(std::span<const Move> scramble, const Solution& sol) {
  FaceletCube f;
  f.apply(scramble);
  f.apply(sol.moves);
  EXPECT_TRUE(f.isSolved());
  std::size_t total = 0;
  for (auto n : sol.phaseLengths) total += n;
  EXPECT_EQ(total, sol.moves.size());
}

}  // namespace

TEST(Solver, PhaseWorstCasesMatchThistlethwaite) {
  EXPECT_EQ(solver().maxPhaseLength(0), 7);
  EXPECT_EQ(solver().maxPhaseLength(1), 10);
  EXPECT_EQ(solver().maxPhaseLength(2), 13);
  EXPECT_EQ(solver().maxPhaseLength(3), 15);
}

TEST(Solver, SolvedCubeNeedsNoMoves) {
  EXPECT_TRUE(solver().solve(CubieCube{}).moves.empty());
  EXPECT_TRUE(solver().solve(std::span<const Move>{}).moves.empty());
}

TEST(Solver, SingleMoves) {
  for (int i = 0; i < kMoveCount; ++i) {
    Move scr[] = {Move::fromIndex(i)};
    Solution s = solver().solve(scr);
    expectSolves(scr, s);
    EXPECT_LE(s.moves.size(), 3u);
  }
}

TEST(Solver, Superflip) {
  auto scr = *parseMoves("U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2");
  Solution s = solver().solve(scr);
  expectSolves(scr, s);
  EXPECT_LE(s.moves.size(), 45u);
}

TEST(Solver, RandomScramblesWithinPhaseBounds) {
  std::mt19937 rng(2024);
  for (int t = 0; t < 300; ++t) {
    std::vector<Move> scr;
    for (int i = 0; i < 25; ++i) scr.push_back(Move::fromIndex(rng() % kMoveCount));
    Solution s = solver().solve(scr);
    expectSolves(scr, s);
    EXPECT_LE(s.phaseLengths[0], 7u);
    EXPECT_LE(s.phaseLengths[1], 10u);
    EXPECT_LE(s.phaseLengths[2], 13u);
    EXPECT_LE(s.phaseLengths[3], 15u);
    EXPECT_LE(s.moves.size(), 45u);
  }
}

TEST(Solver, LongScramble) {
  std::mt19937 rng(7);
  std::vector<Move> scr;
  for (int i = 0; i < 1000; ++i) scr.push_back(Move::fromIndex(rng() % kMoveCount));
  expectSolves(scr, solver().solve(scr));
}

TEST(Solver, RandomValidCubesFromFacelets) {
  // Solve cubes that arrive as stickers, as a library user would supply them.
  std::mt19937 rng(99);
  for (int t = 0; t < 20; ++t) {
    FaceletCube f;
    std::vector<Move> scr;
    for (int i = 0; i < 30; ++i) scr.push_back(Move::fromIndex(rng() % kMoveCount));
    f.apply(scr);
    auto cube = CubieCube::fromFacelets(f);
    ASSERT_TRUE(cube);
    Solution s = solver().solve(*cube);
    f.apply(s.moves);
    EXPECT_TRUE(f.isSolved());
  }
}

TEST(Solver, RejectsUnreachableCube) {
  CubieCube c;
  c.co[0] = 1;
  EXPECT_THROW(solver().solve(c), std::invalid_argument);
}
