#include <gtest/gtest.h>

#include <algorithm>

#include "datalog/ast.h"

using namespace datalog;

TEST(Constant, IntegersBeforeSymbols) {
  EXPECT_LT(Constant::integer(1000000000), Constant::symbol("a"));
  EXPECT_LT(Constant::integer(-2), Constant::integer(5));
  EXPECT_GT(Constant::symbol("b"), Constant::symbol("a"));
}

TEST(Constant, SymbolOrderIsStrcmp) {
  std::vector<std::string> names = {"ab", "a_b", "b", "a", "aa", "a_", "a0"};
  std::vector<Constant> cs;
  for (auto& n : names) cs.push_back(Constant::symbol(n));
  std::sort(cs.begin(), cs.end());
  std::vector<std::string> sorted;
  for (auto& c : cs) sorted.push_back(c.to_string());
  EXPECT_EQ(sorted, (std::vector<std::string>{"a", "a0", "a_", "a_b", "aa",
                                              "ab", "b"}));
}

TEST(Constant, EqualityAndFormatting) {
  EXPECT_EQ(Constant::integer(5), Constant::integer(5));
  EXPECT_NE(Constant::integer(5), Constant::symbol("5"));
  EXPECT_EQ(Constant::integer(-5).to_string(), "-5");
  EXPECT_EQ(Constant::symbol("abc").to_string(), "abc");
}

TEST(Compare, UsesTotalOrder) {
  EXPECT_TRUE(compare_holds(CompareOp::Lt, Constant::integer(5),
                            Constant::symbol("abc")));
  EXPECT_FALSE(compare_holds(CompareOp::Lt, Constant::symbol("b"),
                             Constant::symbol("a")));
  EXPECT_TRUE(compare_holds(CompareOp::Ne, Constant::integer(1),
                            Constant::symbol("a")));
  EXPECT_TRUE(compare_holds(CompareOp::Ge, Constant::integer(3),
                            Constant::integer(3)));
}
