#include <gtest/gtest.h>

#include "datalog/analysis.h"
#include "datalog/parser.h"

using namespace datalog;

namespace {
bool safe(const char* src) { return is_safe(parse_program(src).rules.at(0)); }
}  // namespace

TEST(Safety, SafeRules) {
  EXPECT_TRUE(safe("p(X) :- q(X)."));
  EXPECT_TRUE(safe("p(a)."));
  EXPECT_TRUE(safe("p(X) :- q(X, _), not r(X), X < 3."));
  EXPECT_TRUE(safe("p(a) :- 1 < 2."));
}

TEST(Safety, UnsafeRules) {
  EXPECT_FALSE(safe("p(X)."));
  EXPECT_FALSE(safe("p(_)."));
  EXPECT_FALSE(safe("p(X) :- q(Y)."));
  EXPECT_FALSE(safe("p(X) :- q(X), not r(Y)."));
  EXPECT_FALSE(safe("p(X) :- q(X), not r(_)."));
  EXPECT_FALSE(safe("p(Y) :- q(X), X = Y."));
  EXPECT_FALSE(safe("p(X) :- q(X), Y = 5."));
  EXPECT_FALSE(safe("p(X) :- q(X), X < _."));
  EXPECT_FALSE(safe("p(X) :- not q(X)."));
}

TEST(Safety, CheckThrows) {
  EXPECT_THROW(check_safety(parse_program("q(1). p(X) :- q(Y).")),
               ProgramError);
  EXPECT_NO_THROW(check_safety(parse_program("q(1). p(X) :- q(X).")));
}

TEST(Stratify, OrdersDependenciesFirst) {
  auto comps = stratify(parse_program(
      "s(X) :- n(X), not h(X). h(X) :- l(X, _). n(a). l(a, b)."));
  auto pos = [&](const std::string& name) {
    for (std::size_t i = 0; i < comps.size(); ++i)
      for (auto& k : comps[i])
        if (k.name == name) return static_cast<int>(i);
    return -1;
  };
  EXPECT_LT(pos("h"), pos("s"));
  EXPECT_LT(pos("n"), pos("s"));
  EXPECT_LT(pos("l"), pos("h"));
}

TEST(Stratify, MutualRecursionSharesComponent) {
  auto comps = stratify(parse_program(
      "even(X) :- odd(Y), s(Y, X). odd(X) :- even(Y), s(Y, X)."));
  bool found = false;
  for (auto& c : comps) if (c.size() == 2) found = true;
  EXPECT_TRUE(found);
}

TEST(Stratify, NegativeCycleRejected) {
  EXPECT_THROW(stratify(parse_program("win(X) :- e(X, Y), not win(Y).")),
               ProgramError);
  EXPECT_THROW(stratify(parse_program(
                   "a(X) :- b(X). b(X) :- c(X), not a(X).")),
               ProgramError);
}

TEST(Stratify, SameNameDifferentArityAreDistinct) {
  EXPECT_NO_THROW(stratify(parse_program("r(X) :- q(X), not r(X, X).")));
}
