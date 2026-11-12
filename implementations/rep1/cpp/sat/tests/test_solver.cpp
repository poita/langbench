#include <gtest/gtest.h>

#include <cstdint>
#include <random>
#include <vector>

#include "sat/dimacs.hpp"
#include "sat/solver.hpp"

using sat::Result;
using sat::Solver;

namespace {

using Clauses = std::vector<std::vector<int>>;

bool modelSatisfies(const Solver& s, const Clauses& cs) {
  for (const auto& c : cs) {
    bool sat = false;
    for (int d : c) {
      bool val = s.modelValue(std::abs(d) - 1);
      if (val == (d > 0)) sat = true;
    }
    if (!sat) return false;
  }
  return true;
}

Result solveClauses(Solver& s, int n, const Clauses& cs) {
  sat::Cnf cnf;
  cnf.numVars = n;
  cnf.clauses = cs;
  sat::loadInto(s, cnf);
  return s.solve();
}

bool bruteForce(int n, const Clauses& cs) {
  for (std::uint32_t m = 0; m < (1u << n); ++m) {
    bool all = true;
    for (const auto& c : cs) {
      bool sat = false;
      for (int d : c) {
        bool val = (m >> (std::abs(d) - 1)) & 1;
        if (val == (d > 0)) { sat = true; break; }
      }
      if (!sat) { all = false; break; }
    }
    if (all) return true;
  }
  return false;
}

// PHP(n): n+1 pigeons into n holes; variable p*n + h + 1.
Clauses pigeonhole(int n) {
  Clauses cs;
  for (int p = 0; p <= n; ++p) {
    std::vector<int> c;
    for (int h = 0; h < n; ++h) c.push_back(p * n + h + 1);
    cs.push_back(c);
  }
  for (int h = 0; h < n; ++h)
    for (int p = 0; p <= n; ++p)
      for (int q = p + 1; q <= n; ++q) cs.push_back({-(p * n + h + 1), -(q * n + h + 1)});
  return cs;
}

Clauses random3Sat(int n, int m, std::mt19937& rng) {
  Clauses cs;
  std::uniform_int_distribution<int> var(1, n), sign(0, 1);
  for (int i = 0; i < m; ++i) {
    std::vector<int> c;
    while (c.size() < 3) {
      int v = var(rng);
      bool dup = false;
      for (int d : c) dup |= std::abs(d) == v;
      if (!dup) c.push_back(sign(rng) ? v : -v);
    }
    cs.push_back(c);
  }
  return cs;
}

}  // namespace

TEST(Solver, NoClausesIsSat) {
  Solver s;
  EXPECT_EQ(s.solve(), Result::Sat);
}

TEST(Solver, NoVarsModelEmpty) {
  Solver s;
  s.solve();
  EXPECT_TRUE(s.model().empty());
}

TEST(Solver, EmptyClauseIsUnsat) {
  Solver s;
  s.reserveVars(2);
  EXPECT_FALSE(s.addClause({}));
  EXPECT_EQ(s.solve(), Result::Unsat);
}

TEST(Solver, UnitConflictIsUnsat) {
  Solver s;
  EXPECT_TRUE(s.addClause({1}));
  EXPECT_FALSE(s.addClause({-1}));
  EXPECT_EQ(s.solve(), Result::Unsat);
}

TEST(Solver, TautologyAndDuplicates) {
  Solver s;
  EXPECT_TRUE(s.addClause({1, -1}));
  EXPECT_TRUE(s.addClause({2, 2, 2}));
  ASSERT_EQ(s.solve(), Result::Sat);
  EXPECT_TRUE(s.modelValue(1));
}

TEST(Solver, UnusedVariablesGetAValue) {
  Solver s;
  s.reserveVars(5);
  s.addClause({1});
  ASSERT_EQ(s.solve(), Result::Sat);
  EXPECT_EQ(s.model().size(), 5u);
  EXPECT_TRUE(s.modelValue(0));
}

TEST(Solver, UnitPropagationChain) {
  Solver s;
  s.addClause({1});
  s.addClause({-1, 2});
  s.addClause({-2, 3});
  s.addClause({-3, -1, 4});
  ASSERT_EQ(s.solve(), Result::Sat);
  for (int v = 0; v < 4; ++v) EXPECT_TRUE(s.modelValue(v));
}

TEST(Solver, TinyUnsat) {
  Solver s;
  s.addClause({1, 2});
  s.addClause({-1, 2});
  s.addClause({1, -2});
  s.addClause({-1, -2});
  EXPECT_EQ(s.solve(), Result::Unsat);
}

TEST(Solver, LongClause) {
  Clauses cs;
  std::vector<int> big;
  for (int i = 1; i <= 1000; ++i) big.push_back(-i);
  cs.push_back(big);
  for (int i = 1; i < 1000; ++i) cs.push_back({i});
  Solver s;
  ASSERT_EQ(solveClauses(s, 1000, cs), Result::Sat);
  EXPECT_FALSE(s.modelValue(999));
  EXPECT_TRUE(modelSatisfies(s, cs));
}

TEST(Solver, Pigeonhole) {
  for (int n = 2; n <= 7; ++n) {
    Solver s;
    EXPECT_EQ(solveClauses(s, (n + 1) * n, pigeonhole(n)), Result::Unsat) << "PHP(" << n << ")";
  }
}

TEST(Solver, PigeonholeWithEnoughHolesIsSat) {
  // Drop one pigeon from PHP(5): 5 pigeons, 5 holes.
  Clauses cs = pigeonhole(5);
  cs.erase(cs.begin() + 5);  // remove pigeon 5's "some hole" clause
  Solver s;
  ASSERT_EQ(solveClauses(s, 30, cs), Result::Sat);
  EXPECT_TRUE(modelSatisfies(s, cs));
}

TEST(Solver, RandomSmallAgainstBruteForce) {
  std::mt19937 rng(12345);
  for (int iter = 0; iter < 300; ++iter) {
    int n = 3 + iter % 10;
    int m = static_cast<int>(n * 4.3);
    Clauses cs = random3Sat(n, m, rng);
    Solver s;
    Result r = solveClauses(s, n, cs);
    EXPECT_EQ(r == Result::Sat, bruteForce(n, cs)) << "iter " << iter;
    if (r == Result::Sat) EXPECT_TRUE(modelSatisfies(s, cs)) << "iter " << iter;
  }
}

TEST(Solver, RandomAtPhaseTransitionModelsAreValid) {
  std::mt19937 rng(777);
  int sat = 0, unsat = 0;
  for (int iter = 0; iter < 20; ++iter) {
    Clauses cs = random3Sat(150, 639, rng);
    Solver s;
    Result r = solveClauses(s, 150, cs);
    if (r == Result::Sat) {
      ++sat;
      EXPECT_TRUE(modelSatisfies(s, cs));
    } else {
      ++unsat;
    }
  }
  EXPECT_GT(sat, 0);
  EXPECT_GT(unsat, 0);
}

TEST(Solver, ExercisesRestartsAndReduction) {
  // PHP(8) forces many conflicts; check the machinery was actually used.
  Solver s;
  ASSERT_EQ(solveClauses(s, 72, pigeonhole(8)), Result::Unsat);
  EXPECT_GT(s.stats().conflicts, 1000u);
  EXPECT_GT(s.stats().restarts, 0u);
  EXPECT_GT(s.stats().reductions, 0u);
}

TEST(Solver, FormatsEndToEnd) {
  sat::Cnf cnf = sat::parseDimacs("p cnf 3 2\n1 -2 0\n2 3 0\n");
  Solver s;
  sat::loadInto(s, cnf);
  ASSERT_EQ(s.solve(), Result::Sat);
  EXPECT_TRUE(s.modelValue(0) || !s.modelValue(1));
  EXPECT_TRUE(s.modelValue(1) || s.modelValue(2));
}
