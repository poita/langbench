#include <gtest/gtest.h>

#include <sstream>

#include "sat/dimacs.hpp"

using sat::Cnf;
using sat::parseDimacs;

TEST(Dimacs, Simple) {
  Cnf c = parseDimacs("c hi\np cnf 3 2\n1 -2 0\n2 3 0\n");
  EXPECT_EQ(c.numVars, 3);
  ASSERT_EQ(c.clauses.size(), 2u);
  EXPECT_EQ(c.clauses[0], (std::vector<int>{1, -2}));
  EXPECT_EQ(c.clauses[1], (std::vector<int>{2, 3}));
}

TEST(Dimacs, ClausesSpanLinesAndShareLines) {
  Cnf c = parseDimacs("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0\n");
  ASSERT_EQ(c.clauses.size(), 4u);
  EXPECT_EQ(c.clauses[0], (std::vector<int>{1, 2}));
  EXPECT_EQ(c.clauses[3], (std::vector<int>{1, -2}));
}

TEST(Dimacs, CommentsAndBlanksAnywhere) {
  Cnf c = parseDimacs("\n  \t\ncfoo\n  c bar\np  cnf\t2  1 \n1\nc inside clause\n  \n-2 0\nc\n");
  ASSERT_EQ(c.clauses.size(), 1u);
  EXPECT_EQ(c.clauses[0], (std::vector<int>{1, -2}));
}

TEST(Dimacs, EmptyClauseAndNoTrailingNewline) {
  Cnf c = parseDimacs("p cnf 1 2\n0\n1 0");
  ASSERT_EQ(c.clauses.size(), 2u);
  EXPECT_TRUE(c.clauses[0].empty());
}

TEST(Dimacs, ZeroVarsZeroClauses) {
  Cnf c = parseDimacs("p cnf 0 0");
  EXPECT_EQ(c.numVars, 0);
  EXPECT_TRUE(c.clauses.empty());
}

TEST(Dimacs, Errors) {
  EXPECT_THROW(parseDimacs("1 0\n"), sat::ParseError);                 // no header
  EXPECT_THROW(parseDimacs("p cnf 1 1\n2 0\n"), sat::ParseError);      // out of range
  EXPECT_THROW(parseDimacs("p cnf 1 1\n1\n"), sat::ParseError);        // unterminated
  EXPECT_THROW(parseDimacs("p cnf 1 2\n1 0\n"), sat::ParseError);      // count mismatch
  EXPECT_THROW(parseDimacs("p cnf 1 1\nx 0\n"), sat::ParseError);      // junk token
  EXPECT_THROW(parseDimacs("p cnf 1\n"), sat::ParseError);             // bad header
}

TEST(Dimacs, WriteSat) {
  std::ostringstream os;
  sat::writeResult(os, sat::Result::Sat, {true, false, true});
  EXPECT_EQ(os.str(), "SAT\n1 -2 3 0\n");
}

TEST(Dimacs, WriteSatNoVars) {
  std::ostringstream os;
  sat::writeResult(os, sat::Result::Sat, {});
  EXPECT_EQ(os.str(), "SAT\n0\n");
}

TEST(Dimacs, WriteUnsat) {
  std::ostringstream os;
  sat::writeResult(os, sat::Result::Unsat, {});
  EXPECT_EQ(os.str(), "UNSAT\n");
}
