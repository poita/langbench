#include "bigint/query.hpp"

#include <gtest/gtest.h>

#include <sstream>

using bigint::evaluate_query;

TEST(Query, Operators) {
  EXPECT_EQ(evaluate_query("12 + 30"), "42");
  EXPECT_EQ(evaluate_query("5 - 7"), "-2");
  EXPECT_EQ(evaluate_query("-5 * 0"), "0");
  EXPECT_EQ(evaluate_query("-7 / 2"), "-3");
  EXPECT_EQ(evaluate_query("-7 % 2"), "-1");
  EXPECT_EQ(evaluate_query("2 ^ 10"), "1024");
  EXPECT_EQ(evaluate_query("-3 cmp -2"), "-1");
  EXPECT_EQ(evaluate_query("007 cmp 7"), "0");
  EXPECT_EQ(evaluate_query("9 cmp 1"), "1");
}

TEST(Query, ErrorCases) {
  EXPECT_EQ(evaluate_query("1 / 0"), "error");
  EXPECT_EQ(evaluate_query("0 % 0"), "error");
  EXPECT_EQ(evaluate_query("5 / -0"), "error");
  EXPECT_EQ(evaluate_query("2 ^ -1"), "error");
  EXPECT_EQ(evaluate_query("5 ^ -0"), "1");
  EXPECT_EQ(evaluate_query("-0 ^ -00"), "1");
}

TEST(Query, NeverNegativeZero) {
  EXPECT_EQ(evaluate_query("-0 + 0"), "0");
  EXPECT_EQ(evaluate_query("-7 % 7"), "0");
  EXPECT_EQ(evaluate_query("-1 / 2"), "0");
}

TEST(Query, MalformedThrows) {
  EXPECT_THROW(evaluate_query("1 +"), std::invalid_argument);
  EXPECT_THROW(evaluate_query("1 ? 2"), std::invalid_argument);
  EXPECT_THROW(evaluate_query("x + 2"), std::invalid_argument);
}

TEST(Query, StreamRunner) {
  std::istringstream in("12 + 30\n1 / 0\n2 ^ 3");  // no final newline
  std::ostringstream out;
  bigint::run_queries(in, out);
  EXPECT_EQ(out.str(), "42\nerror\n8\n");

  std::istringstream empty("");
  std::ostringstream none;
  bigint::run_queries(empty, none);
  EXPECT_EQ(none.str(), "");
}
