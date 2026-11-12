#include <gtest/gtest.h>

#include "datalog/analysis.h"
#include "datalog/parser.h"

using namespace datalog;

namespace {
bool unsafe(const char* src) { return find_unsafe_rule(parse_program(src)).has_value(); }
bool stratifiable(const char* src) {
  Program p = parse_program(src);
  return stratify(p, PredicateTable::of(p)).has_value();
}
}  // namespace

TEST(Safety, SafeRules) {
  EXPECT_FALSE(unsafe("p(X) :- q(X, _), not r(X), X < 5."));
  EXPECT_FALSE(unsafe("p(a). p(a) :- 1 < 2."));
}

TEST(Safety, UnsafeRules) {
  EXPECT_TRUE(unsafe("p(X)."));
  EXPECT_TRUE(unsafe("p(_)."));
  EXPECT_TRUE(unsafe("p(X) :- q(Y)."));
  EXPECT_TRUE(unsafe("p(X) :- q(X), not r(Y)."));
  EXPECT_TRUE(unsafe("p(X) :- q(X), not r(_)."));
  EXPECT_TRUE(unsafe("p(Y) :- q(X), X = Y."));
  EXPECT_TRUE(unsafe("p(X) :- q(X), Y = 5."));
  EXPECT_TRUE(unsafe("p(X) :- q(X), X < _."));
}

TEST(Stratification, NegativeCycleRejected) {
  EXPECT_FALSE(stratifiable("win(X) :- edge(X, Y), not win(Y)."));
  EXPECT_FALSE(stratifiable("a(X) :- b(X), not c(X). c(X) :- d(X), a(X)."));
  EXPECT_FALSE(stratifiable("a(X) :- d(X), not b(X). b(X) :- d(X), not a(X)."));
}

TEST(Stratification, PositiveCyclesAndNegationAcrossComponentsAllowed) {
  EXPECT_TRUE(stratifiable("p(X) :- q(X). q(X) :- p(X)."));
  EXPECT_TRUE(stratifiable("s(X) :- n(X), not h(X). h(X) :- l(X, _). r(X) :- r(X), l(X, X)."));
}

TEST(Stratification, ArityDistinguishesPredicates) {
  EXPECT_TRUE(stratifiable("r(X) :- s(X), not r(X, X)."));
}

TEST(Stratification, ComponentsAreDependenciesFirst) {
  Program p = parse_program("c(X) :- b(X). b(X) :- a(X). a(1).");
  PredicateTable t = PredicateTable::of(p);
  auto s = stratify(p, t);
  ASSERT_TRUE(s.has_value());
  PredId a = *t.find("a", 1), b = *t.find("b", 1), c = *t.find("c", 1);
  EXPECT_LT(s->component_of[a], s->component_of[b]);
  EXPECT_LT(s->component_of[b], s->component_of[c]);
}
