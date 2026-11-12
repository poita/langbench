#include <gtest/gtest.h>

#include <algorithm>
#include <random>
#include <vector>

#include "sat/dimacs.hpp"
#include "sat/solver.hpp"

using namespace sat;

namespace {

bool brute_force_sat(const Cnf& cnf) {
    for (unsigned m = 0; m < (1u << cnf.num_vars); ++m) {
        std::vector<bool> model(cnf.num_vars);
        for (int v = 0; v < cnf.num_vars; ++v) model[v] = (m >> v) & 1;
        if (satisfies(cnf, model)) return true;
    }
    return false;
}

Result solve_cnf(const Cnf& cnf, std::vector<bool>* model = nullptr) {
    Solver s;
    if (!load(s, cnf)) return Result::Unsat;
    Result r = s.solve();
    if (r == Result::Sat && model) *model = s.model();
    return r;
}

Cnf random_ksat(std::mt19937& rng, int vars, int clauses, int k) {
    Cnf cnf;
    cnf.num_vars = vars;
    for (int i = 0; i < clauses; ++i) {
        std::vector<int> c;
        for (int j = 0; j < k; ++j) {
            int v = static_cast<int>(rng() % vars) + 1;
            c.push_back(rng() & 1 ? v : -v);
        }
        cnf.clauses.push_back(c);
    }
    return cnf;
}

// PHP(n): n+1 pigeons into n holes; unsatisfiable.
Cnf pigeonhole(int holes) {
    int pigeons = holes + 1;
    Cnf cnf;
    cnf.num_vars = pigeons * holes;
    auto var = [&](int p, int h) { return p * holes + h + 1; };
    for (int p = 0; p < pigeons; ++p) {
        std::vector<int> c;
        for (int h = 0; h < holes; ++h) c.push_back(var(p, h));
        cnf.clauses.push_back(c);
    }
    for (int h = 0; h < holes; ++h)
        for (int p = 0; p < pigeons; ++p)
            for (int q = p + 1; q < pigeons; ++q) cnf.clauses.push_back({-var(p, h), -var(q, h)});
    return cnf;
}

}  // namespace

TEST(Luby, Sequence) {
    std::vector<std::uint64_t> expect = {1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8};
    for (std::size_t i = 0; i < expect.size(); ++i) EXPECT_EQ(luby(i), expect[i]) << i;
}

TEST(Solver, NoClausesIsSat) {
    Solver s;
    EXPECT_EQ(s.solve(), Result::Sat);
    Solver t;
    t.new_var();
    t.new_var();
    EXPECT_EQ(t.solve(), Result::Sat);
    EXPECT_EQ(t.model().size(), 2u);
}

TEST(Solver, EmptyClauseIsUnsat) {
    Solver s;
    s.new_var();
    EXPECT_TRUE(s.add_clause({Lit(0)}));
    EXPECT_FALSE(s.add_clause({}));
    EXPECT_FALSE(s.okay());
    EXPECT_EQ(s.solve(), Result::Unsat);
}

TEST(Solver, TautologyAndDuplicatesAreHandled) {
    Solver s;
    Var a = s.new_var(), b = s.new_var();
    EXPECT_TRUE(s.add_clause({Lit(a), Lit(a, true)}));        // tautology
    EXPECT_TRUE(s.add_clause({Lit(a), Lit(a), Lit(b)}));       // duplicate literal
    EXPECT_TRUE(s.add_clause({Lit(a, true), Lit(a, true)}));   // unit !a
    ASSERT_EQ(s.solve(), Result::Sat);
    EXPECT_FALSE(s.model_value(a));
    EXPECT_TRUE(s.model_value(b));
}

TEST(Solver, ContradictoryUnits) {
    Solver s;
    Var a = s.new_var();
    EXPECT_TRUE(s.add_clause({Lit(a)}));
    EXPECT_FALSE(s.add_clause({Lit(a, true)}));
    EXPECT_EQ(s.solve(), Result::Unsat);
}

TEST(Solver, UnitPropagationAtRootChains) {
    Cnf cnf = parse_dimacs("p cnf 4 4\n1 0\n-1 2 0\n-2 3 0\n-3 -4 0\n");
    std::vector<bool> m;
    ASSERT_EQ(solve_cnf(cnf, &m), Result::Sat);
    EXPECT_TRUE(m[0] && m[1] && m[2] && !m[3]);
}

TEST(Solver, SpecExamples) {
    Cnf a = parse_dimacs("p cnf 3 2\n1 -2 0\n2 3 0\n");
    std::vector<bool> m;
    ASSERT_EQ(solve_cnf(a, &m), Result::Sat);
    EXPECT_TRUE(satisfies(a, m));
    EXPECT_EQ(solve_cnf(parse_dimacs("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0")), Result::Unsat);
}

TEST(Solver, DimacsConvenienceOverload) {
    Solver s;
    s.new_var();
    s.new_var();
    EXPECT_TRUE(s.add_clause_dimacs({1, -2}));
    EXPECT_TRUE(s.add_clause_dimacs({-1}));
    ASSERT_EQ(s.solve(), Result::Sat);
    EXPECT_FALSE(s.model_value(0));
    EXPECT_FALSE(s.model_value(1));
}

TEST(Solver, SingleHugeClause) {
    Cnf cnf;
    cnf.num_vars = 1000;
    std::vector<int> c;
    for (int i = 1; i <= 1000; ++i) c.push_back(-i);
    cnf.clauses.push_back(c);
    std::vector<bool> m;
    ASSERT_EQ(solve_cnf(cnf, &m), Result::Sat);
    EXPECT_TRUE(satisfies(cnf, m));
}

TEST(Solver, PigeonholeIsUnsat) {
    for (int n = 2; n <= 7; ++n) EXPECT_EQ(solve_cnf(pigeonhole(n)), Result::Unsat) << "PHP(" << n << ")";
}

TEST(Solver, PigeonholeStatsShowLearning) {
    Cnf cnf = pigeonhole(6);
    Solver s;
    ASSERT_TRUE(load(s, cnf));
    EXPECT_EQ(s.solve(), Result::Unsat);
    EXPECT_GT(s.stats().conflicts, 0u);
}

TEST(Solver, RandomSmallFormulasMatchBruteForce) {
    std::mt19937 rng(12345);
    int sat_count = 0, unsat_count = 0;
    for (int iter = 0; iter < 400; ++iter) {
        int vars = 3 + rng() % 10;
        int clauses = static_cast<int>(vars * (2.0 + (rng() % 40) / 10.0));
        Cnf cnf = random_ksat(rng, vars, clauses, 1 + rng() % 3 + 1);
        std::vector<bool> m;
        Result r = solve_cnf(cnf, &m);
        ASSERT_EQ(r == Result::Sat, brute_force_sat(cnf)) << "iteration " << iter;
        if (r == Result::Sat) {
            EXPECT_TRUE(satisfies(cnf, m));
            ++sat_count;
        } else {
            ++unsat_count;
        }
    }
    EXPECT_GT(sat_count, 20);
    EXPECT_GT(unsat_count, 20);
}

TEST(Solver, PhaseTransition3SatModelsAreValid) {
    std::mt19937 rng(2024);
    int sat_seen = 0, unsat_seen = 0;
    for (int iter = 0; iter < 20; ++iter) {
        Cnf cnf = random_ksat(rng, 150, 639, 3);
        std::vector<bool> m;
        if (solve_cnf(cnf, &m) == Result::Sat) {
            EXPECT_TRUE(satisfies(cnf, m));
            ++sat_seen;
        } else {
            ++unsat_seen;
        }
    }
    EXPECT_GT(sat_seen, 0);
    EXPECT_GT(unsat_seen, 0);
}

TEST(Solver, ForcesRestartsAndReductions) {
    // Hard enough to exceed several Luby restarts and to trigger clause deletion.
    Cnf cnf = pigeonhole(8);
    Solver s;
    ASSERT_TRUE(load(s, cnf));
    EXPECT_EQ(s.solve(), Result::Unsat);
    EXPECT_GT(s.stats().restarts, 0u);
    EXPECT_GT(s.stats().reductions, 0u);
    EXPECT_GT(s.stats().deleted_clauses, 0u);
}
