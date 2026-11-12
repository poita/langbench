#include <gtest/gtest.h>

#include <random>

#include "mdiff/myers.hpp"
#include "oracle.hpp"

using namespace mdiff;
using Ids = std::vector<LineId>;

namespace {
void check(const Ids& a, const Ids& b) {
  EditScript s = myers_diff(a, b);
  ASSERT_TRUE(testutil::script_valid(s, a, b));
  EXPECT_EQ(script_cost(s), a.size() + b.size() - 2 * testutil::lcs_length(a, b));
}
}  // namespace

TEST(Myers, BothEmpty) { EXPECT_TRUE(myers_diff({}, {}).empty()); }

TEST(Myers, EmptyToSomething) {
  EditScript s = myers_diff({}, {1, 2, 3});
  EXPECT_EQ(script_cost(s), 3u);
  check({}, {1, 2, 3});
  check({1, 2, 3}, {});
}

TEST(Myers, Identical) {
  Ids a = {1, 2, 3, 4};
  EditScript s = myers_diff(a, a);
  EXPECT_EQ(s.size(), 4u);
  EXPECT_EQ(script_cost(s), 0u);
}

TEST(Myers, PaperExample) {
  // abcabba -> cbabac, D = 5
  Ids a = {0, 1, 2, 0, 1, 1, 0}, b = {2, 1, 0, 1, 0, 2};
  EditScript s = myers_diff(a, b);
  EXPECT_EQ(script_cost(s), 5u);
  check(a, b);
}

TEST(Myers, Disjoint) {
  Ids a, b;
  for (LineId i = 0; i < 300; ++i) { a.push_back(i); b.push_back(1000 + i); }
  EditScript s = myers_diff(a, b);
  EXPECT_EQ(script_cost(s), 600u);
  check(a, b);
}

TEST(Myers, DuplicatesHeavy) {
  check({0, 0, 0, 1, 0, 0}, {0, 1, 0, 0, 0, 1});
  check({0, 0, 0, 0}, {0, 0});
}

TEST(Myers, AllOddEvenSizeCombinations) {
  // Exhaustive over a binary alphabet: exercises both parity branches.
  for (int na = 0; na <= 6; ++na)
    for (int nb = 0; nb <= 6; ++nb)
      for (int ma = 0; ma < (1 << na); ++ma)
        for (int mb = 0; mb < (1 << nb); ++mb) {
          Ids a, b;
          for (int i = 0; i < na; ++i) a.push_back((ma >> i) & 1);
          for (int i = 0; i < nb; ++i) b.push_back((mb >> i) & 1);
          check(a, b);
          if (::testing::Test::HasFatalFailure()) return;
        }
}

TEST(Myers, RandomSmallAlphabet) {
  std::mt19937 rng(12345);
  for (int iter = 0; iter < 2000; ++iter) {
    int alpha = 1 + rng() % 6;
    Ids a(rng() % 60), b(rng() % 60);
    for (auto& x : a) x = rng() % alpha;
    for (auto& x : b) x = rng() % alpha;
    check(a, b);
    if (HasFatalFailure()) return;
  }
}

TEST(Myers, RandomEditsOfBase) {
  std::mt19937 rng(777);
  for (int iter = 0; iter < 200; ++iter) {
    Ids a(200 + rng() % 200);
    for (auto& x : a) x = rng() % 50;
    Ids b = a;
    for (int e = 0; e < 20; ++e) {
      switch (rng() % 3) {
        case 0: if (!b.empty()) b.erase(b.begin() + rng() % b.size()); break;
        case 1: b.insert(b.begin() + rng() % (b.size() + 1), rng() % 50); break;
        default: if (!b.empty()) b[rng() % b.size()] = rng() % 50; break;
      }
    }
    check(a, b);
    if (HasFatalFailure()) return;
  }
}

TEST(Myers, LargeWorstCaseDoesNotRecurseDeeply) {
  Ids a, b;
  for (LineId i = 0; i < 20000; ++i) { a.push_back(i); b.push_back(1000000 + i); }
  EXPECT_EQ(script_cost(myers_diff(a, b)), 40000u);  // D = N+M, quadratic but finite
}
