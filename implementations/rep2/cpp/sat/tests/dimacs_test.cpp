#include <gtest/gtest.h>

#include <sstream>

#include "sat/dimacs.hpp"
#include "sat/solver.hpp"

using namespace sat;

TEST(Dimacs, SimpleFormula) {
    Cnf cnf = parse_dimacs("c hi\np cnf 3 2\n1 -2 0\n2 3 0\n");
    EXPECT_EQ(cnf.num_vars, 3);
    ASSERT_EQ(cnf.clauses.size(), 2u);
    EXPECT_EQ(cnf.clauses[0], (std::vector<int>{1, -2}));
    EXPECT_EQ(cnf.clauses[1], (std::vector<int>{2, 3}));
}

TEST(Dimacs, ClausesSpanLinesAndShareLines) {
    Cnf cnf = parse_dimacs("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0");
    ASSERT_EQ(cnf.clauses.size(), 4u);
    EXPECT_EQ(cnf.clauses[0], (std::vector<int>{1, 2}));
    EXPECT_EQ(cnf.clauses[3], (std::vector<int>{1, -2}));
}

TEST(Dimacs, CommentsBlanksAndIndentationAnywhere) {
    Cnf cnf = parse_dimacs("  \n\t c first\ncfoo\n  p   cnf\t2  2 \n1\nc middle of a clause\n \t-2 0\n\n0\nc end");
    ASSERT_EQ(cnf.clauses.size(), 2u);
    EXPECT_EQ(cnf.clauses[0], (std::vector<int>{1, -2}));
    EXPECT_TRUE(cnf.clauses[1].empty());
}

TEST(Dimacs, EmptyFormula) {
    Cnf cnf = parse_dimacs("p cnf 0 0");
    EXPECT_EQ(cnf.num_vars, 0);
    EXPECT_TRUE(cnf.clauses.empty());
}

TEST(Dimacs, ReadsFromStream) {
    std::istringstream in("p cnf 1 1\n-1 0\n");
    Cnf cnf = parse_dimacs(in);
    EXPECT_EQ(cnf.clauses[0], (std::vector<int>{-1}));
}

TEST(Dimacs, RejectsMalformedInput) {
    EXPECT_THROW(parse_dimacs("1 0\n"), ParseError);                 // no header
    EXPECT_THROW(parse_dimacs("p cnf 1 1\n2 0\n"), ParseError);      // out of range
    EXPECT_THROW(parse_dimacs("p cnf 1 1\n1\n"), ParseError);        // unterminated
    EXPECT_THROW(parse_dimacs("p cnf 1 2\n1 0\n"), ParseError);      // count mismatch
    EXPECT_THROW(parse_dimacs("p cnf 1 0\np cnf 1 0\n"), ParseError);  // two headers
    EXPECT_THROW(parse_dimacs("p cnf 1 1\nx 0\n"), ParseError);      // not an integer
}

TEST(Dimacs, LoadAndSatisfies) {
    Cnf cnf = parse_dimacs("p cnf 3 2\n1 -2 0\n2 3 0\n");
    Solver s;
    ASSERT_TRUE(load(s, cnf));
    EXPECT_EQ(s.num_vars(), 3);
    ASSERT_EQ(s.solve(), Result::Sat);
    EXPECT_TRUE(satisfies(cnf, s.model()));
    EXPECT_FALSE(satisfies(cnf, {false, true, false}));
}

TEST(Dimacs, WriteResult) {
    std::ostringstream a, b, c;
    write_result(a, Result::Unsat, {});
    EXPECT_EQ(a.str(), "UNSAT\n");
    write_result(b, Result::Sat, {true, false, true});
    EXPECT_EQ(b.str(), "SAT\n1 -2 3 0\n");
    write_result(c, Result::Sat, {});
    EXPECT_EQ(c.str(), "SAT\n0\n");
}
