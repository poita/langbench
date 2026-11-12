#include <gtest/gtest.h>

#include "datalog/datalog.h"

using namespace datalog;

namespace {
std::string run(const std::string& s) { return run_program(s); }
}  // namespace

TEST(Engine, TransitiveClosureExample) {
  EXPECT_EQ(run("edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).\n"
                "path(X, Y) :- edge(X, Y).\n"
                "path(X, Z) :- edge(X, Y), path(Y, Z).\n"
                "?- path(1, X). ?- path(4, X). ?- path(X, X).\n"),
            "path(1, 1)\npath(1, 2)\npath(1, 3)\npath(1, 4)\n-- 4\n-- 0\n"
            "path(1, 1)\npath(2, 2)\npath(3, 3)\n-- 3\n");
}

TEST(Engine, NegationComparisonsMixedConstants) {
  EXPECT_EQ(run("% nodes and links\n"
                "node(a). node(b). node(c). node(5). node(-2).\n"
                "link(a, b). link(b, 5). link(5, 5).\n"
                "reach(X, Y) :- link(X, Y).\n"
                "reach(X, Z) :- reach(X, Y), link(Y, Z).\n"
                "sink(X) :- node(X), not hasout(X).\n"
                "hasout(X) :- link(X, _).\n"
                "small(X) :- node(X), X < a.\n"
                "?- sink(X). ?- small(X). ?- reach(a, X). ?- reach(X, X).\n"),
            "sink(-2)\nsink(c)\n-- 2\nsmall(-2)\nsmall(5)\n-- 2\n"
            "reach(a, 5)\nreach(a, b)\n-- 2\nreach(5, 5)\n-- 1\n");
}

TEST(Engine, ErrorsPrintOnlyError) {
  EXPECT_EQ(run("edge(1, 2).\nwin(X) :- edge(X, Y), not win(Y).\n?- win(X).\n"), "error\n");
  EXPECT_EQ(run("q(1).\n?- q(X).\np(X) :- q(Y).\n?- p(X).\n"), "error\n");
}

TEST(Engine, NoQueriesNoOutput) { EXPECT_EQ(run("p(1). q(X) :- p(X)."), ""); }
TEST(Engine, EmptyProgram) { EXPECT_EQ(run(" % nothing\n"), ""); }

TEST(Engine, NonLinearRecursion) {
  // link(X,Z) :- link(X,Y), link(Y,Z) over a 40-chain: all i<j pairs.
  std::string src;
  for (int i = 0; i < 40; ++i) src += "link(" + std::to_string(i) + ", " + std::to_string(i + 1) + ").";
  src += "link(X, Z) :- link(X, Y), link(Y, Z). ?- link(_, _).";
  Program p = parse_program(src);
  Engine e(p);
  EXPECT_EQ(e.size("link", 2), 41u * 40u / 2u);
}

TEST(Engine, MutualRecursionEvenOdd) {
  std::string src = "num(0). succ(0, 1). succ(1, 2). succ(2, 3). succ(3, 4). succ(4, 5).\n"
                    "even(0).\n"
                    "odd(Y) :- even(X), succ(X, Y).\n"
                    "even(Y) :- odd(X), succ(X, Y).\n"
                    "?- even(X). ?- odd(X).";
  EXPECT_EQ(run(src), "even(0)\neven(2)\neven(4)\n-- 3\nodd(1)\nodd(3)\nodd(5)\n-- 3\n");
}

TEST(Engine, MutualNonLinearJoinsUseDeltaInEveryPosition) {
  // a and b feed each other; c(X,Z) :- a(X,Y), b(Y,Z) needs delta in both atoms.
  std::string src = "a(1, 2). b(2, 3). a(3, 4). b(4, 5).\n"
                    "a(X, Z) :- b(X, Y), c(Y, Z).\n"
                    "b(X, Z) :- a(X, Y), c(Y, Z).\n"
                    "c(X, Z) :- a(X, Y), b(Y, Z).\n"
                    "c(X, Z) :- b(X, Y), a(Y, Z).\n"
                    "?- c(X, Y).";
  EXPECT_EQ(run(src), "c(1, 3)\nc(2, 4)\nc(3, 5)\n-- 3\n");
}

TEST(Engine, RepeatedVariablesAndWildcards) {
  EXPECT_EQ(run("e(1, 1). e(1, 2). e(2, 2). loop(X) :- e(X, X).\n"
                "?- loop(X). ?- e(X, X). ?- e(_, _). ?- e(1, _). ?- e(X, Y)."),
            "loop(1)\nloop(2)\n-- 2\n"
            "e(1, 1)\ne(2, 2)\n-- 2\n"
            "e(1, 1)\ne(1, 2)\ne(2, 2)\n-- 3\n"
            "e(1, 1)\ne(1, 2)\n-- 2\n"
            "e(1, 1)\ne(1, 2)\ne(2, 2)\n-- 3\n");
}

TEST(Engine, UnknownPredicatesAndConstantsAreEmpty) {
  EXPECT_EQ(run("p(a). q(X) :- p(X), not nothere(X). ?- zzz(X). ?- p(unknown). ?- q(X)."),
            "-- 0\n-- 0\nq(a)\n-- 1\n");
}

TEST(Engine, SameNameDifferentArity) {
  EXPECT_EQ(run("r(1). s(X) :- r(X), not r(X, X). ?- s(X). ?- r(X, Y)."), "s(1)\n-- 1\n-- 0\n");
}

TEST(Engine, ComparisonOrdering) {
  EXPECT_EQ(run("v(5). v(a). v(b). v(-1). v(a0).\n"
                "lt(X, Y) :- v(X), v(Y), X < Y.\n"
                "ge_a(X) :- v(X), X >= a. ne(X) :- v(X), X != a, X != 5.\n"
                "?- ge_a(X). ?- ne(X). ?- lt(a, Y)."),
            "ge_a(a)\nge_a(a0)\nge_a(b)\n-- 3\n"
            "ne(-1)\nne(a0)\nne(b)\n-- 3\n"
            "lt(a, a0)\nlt(a, b)\n-- 2\n");
}

TEST(Engine, ConstantOnlyBodiesAndFactsAndRulesMix) {
  EXPECT_EQ(run("p(1). p(X) :- q(X). q(2). t(a) :- 1 < 2. u(a) :- 2 < 1. ?- p(X). ?- t(X). ?- u(X)."),
            "p(1)\np(2)\n-- 2\nt(a)\n-- 1\n-- 0\n");
}

TEST(Engine, QueryAnswersInInputOrderRegardlessOfClausePosition) {
  EXPECT_EQ(run("?- p(X). p(1). ?- p(1). p(2)."), "p(1)\np(2)\n-- 2\np(1)\n-- 1\n");
}

TEST(Engine, ApiQuery) {
  Program prog = parse_program("p(b, 1). p(a, 2). p(a, 1).");
  Engine e(prog);
  Atom q;
  q.predicate = "p";
  q.args = {Term::variable("X"), Term::constant(Constant::integer(1))};
  auto rows = e.query(q);
  ASSERT_EQ(rows.size(), 2u);
  EXPECT_EQ(rows[0][0], Constant::symbol("a"));
  EXPECT_EQ(rows[1][0], Constant::symbol("b"));
}

TEST(Engine, ThrowsOnUnsafeAndUnstratifiable) {
  EXPECT_THROW(Engine(parse_program("p(X).")), ProgramError);
  EXPECT_THROW(Engine(parse_program("p(X) :- q(X), not p(X).")), ProgramError);
}
