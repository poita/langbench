#include <gtest/gtest.h>

#include "sat/types.hpp"

using sat::LBool;
using sat::Lit;

TEST(Lit, DimacsRoundTrip) {
  for (int d : {1, -1, 2, -2, 17, -17, 2000, -2000}) {
    EXPECT_EQ(Lit::fromDimacs(d).toDimacs(), d);
  }
}

TEST(Lit, VarAndSign) {
  Lit pos = Lit::fromDimacs(5), neg = Lit::fromDimacs(-5);
  EXPECT_EQ(pos.var(), 4);
  EXPECT_EQ(neg.var(), 4);
  EXPECT_FALSE(pos.negated());
  EXPECT_TRUE(neg.negated());
}

TEST(Lit, Negation) {
  Lit l = Lit::fromDimacs(3);
  EXPECT_EQ(~l, Lit::fromDimacs(-3));
  EXPECT_EQ(~~l, l);
  EXPECT_NE(l.index(), (~l).index());
}

TEST(LBool, FlipIf) {
  EXPECT_EQ(sat::flipIf(LBool::True, true), LBool::False);
  EXPECT_EQ(sat::flipIf(LBool::False, true), LBool::True);
  EXPECT_EQ(sat::flipIf(LBool::Undef, true), LBool::Undef);
  EXPECT_EQ(sat::flipIf(LBool::True, false), LBool::True);
}
