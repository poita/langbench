#include <gtest/gtest.h>

#include "datalog/datalog.h"

using namespace datalog;

namespace {
std::string run(const std::string& src) { return run_program(src); }
}  // namespace

TEST(Engine, TransitiveClosure) {
  EXPECT_EQ(run("edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).\n"
                "path(X, Y) :- edge(X, Y).\n"
                "path(X, Z) :- edge(X, Y), path(Y, Z).\n"
                "?- path(1, X). ?- path(4, X). ?- path(X, X)."),
            "path(1, 1)\npath(1, 2)\npath(1, 3)\npath(1, 4)\n-- 4\n"
            "-- 0\n"
            "path(1, 1)\npath(2, 2)\npath(3, 3)\n-- 3\n");
}

TEST(Engine, NegationComparisonsAndMixedConstants) {
  EXPECT_EQ(run("% nodes and links\n"
                "node(a). node(b). node(c). node(5). node(-2).\n"
                "link(a, b). link(b, 5). link(5, 5).\n"
                "reach(X, Y) :- link(X, Y).\n"
                "reach(X, Z) :- reach(X, Y), link(Y, Z).\n"
                "sink(X) :- node(X), not hasout(X).\n"
                "hasout(X) :- link(X, _).\n"
                "small(X) :- node(X), X < a.\n"
                "?- sink(X). ?- small(X). ?- reach(a, X). ?- reach(X, X)."),
            "sink(-2)\nsink(c)\n-- 2\n"
            "small(-2)\nsmall(5)\n-- 2\n"
            "reach(a, 5)\nreach(a, b)\n-- 2\n"
            "reach(5, 5)\n-- 1\n");
}

TEST(Engine, UnstratifiableIsError) {
  EXPECT_EQ(run("edge(1, 2).\nwin(X) :- edge(X, Y), not win(Y).\n?- win(X)."),
            "error\n");
}

TEST(Engine, UnsafeIsErrorEvenAfterEarlierQueries) {
  EXPECT_EQ(run("q(1).\n?- q(X).\np(X) :- q(Y).\n?- p(X)."), "error\n");
  EXPECT_EQ(run("p(X)."), "error\n");
}

TEST(Engine, NoQueriesNoOutput) {
  EXPECT_EQ(run("p(1). q(X) :- p(X)."), "");
  EXPECT_EQ(run(""), "");
}

TEST(Engine, NonLinearRecursion) {
  std::string src;
  for (int i = 0; i < 30; ++i)
    src += "link(" + std::to_string(i) + ", " + std::to_string(i + 1) + ").\n";
  src += "link(X, Z) :- link(X, Y), link(Y, Z).\n?- link(0, X).";
  std::string out = run(src);
  EXPECT_NE(out.find("link(0, 30)\n"), std::string::npos);
  EXPECT_EQ(out.substr(out.rfind("-- ")), "-- 30\n");
}

TEST(Engine, MutualRecursion) {
  EXPECT_EQ(run("s(0, 1). s(1, 2). s(2, 3). s(3, 4).\n"
                "even(0).\n"
                "odd(X) :- even(Y), s(Y, X).\n"
                "even(X) :- odd(Y), s(Y, X).\n"
                "?- even(X). ?- odd(X)."),
            "even(0)\neven(2)\neven(4)\n-- 3\nodd(1)\nodd(3)\n-- 2\n");
}

TEST(Engine, RepeatedVariablesAndAnonymous) {
  EXPECT_EQ(run("edge(1, 1). edge(1, 2). edge(2, 2).\n"
                "loop(X) :- edge(X, X).\n"
                "?- loop(X). ?- edge(X, X). ?- edge(_, _). ?- edge(1, _)."),
            "loop(1)\nloop(2)\n-- 2\n"
            "edge(1, 1)\nedge(2, 2)\n-- 2\n"
            "edge(1, 1)\nedge(1, 2)\nedge(2, 2)\n-- 3\n"
            "edge(1, 1)\nedge(1, 2)\n-- 2\n");
}

TEST(Engine, ArityDistinguishesPredicates) {
  EXPECT_EQ(run("r(1). p(X) :- r(X). ?- r(X, Y). ?- p(X)."),
            "-- 0\np(1)\n-- 1\n");
}

TEST(Engine, MissingPredicatesAreEmpty) {
  EXPECT_EQ(run("p(X) :- q(X), not r(X). ?- p(X). ?- nope(1, 2)."),
            "-- 0\n-- 0\n");
}

TEST(Engine, ConstantOnlyBody) {
  EXPECT_EQ(run("p(a) :- 1 < 2. q(a) :- 2 < 1. r(a) :- not s(b). "
                "?- p(X). ?- q(X). ?- r(X)."),
            "p(a)\n-- 1\n-- 0\nr(a)\n-- 1\n");
}

TEST(Engine, ComparisonsOverTotalOrder) {
  EXPECT_EQ(run("v(b). v(a). v(3). v(-1).\n"
                "lt(X, Y) :- v(X), v(Y), X < Y, Y = b.\n"
                "?- lt(X, Y)."),
            "lt(-1, b)\nlt(3, b)\nlt(a, b)\n-- 3\n");
}

TEST(Engine, FactsAndRulesForSamePredicate) {
  EXPECT_EQ(run("p(1). p(X) :- q(X). q(2). p(2). ?- p(X)."),
            "p(1)\np(2)\n-- 2\n");
}

TEST(Engine, ModelApi) {
  Model m = evaluate(parse_program("e(1,2). e(2,3). t(X,Y) :- e(X,Y)."));
  EXPECT_EQ(m.size("t", 2), 2u);
  EXPECT_EQ(m.size("t", 1), 0u);
  Program q = parse_program("?- t(X, 3).");
  auto rows = m.query(q.queries[0].atom);
  ASSERT_EQ(rows.size(), 1u);
  EXPECT_EQ(rows[0][0], Constant::integer(2));
  EXPECT_THROW(evaluate(parse_program("p(X) :- not q(X).")), ProgramError);
}
