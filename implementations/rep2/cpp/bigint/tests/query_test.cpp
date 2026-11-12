#include <gtest/gtest.h>

#include "bigint/bigint.hpp"
#include "bigint/query.hpp"

using bigint::evaluate_queries;
using bigint::evaluate_query;

TEST(Query, SpecExamples) {
    EXPECT_EQ(evaluate_queries("12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n"), "42\n-2\n-3\n-1\n");
    EXPECT_EQ(evaluate_queries("-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0\n"),
              "0\n0\n0\n100000000000000000000\n1024\n1\n");
    EXPECT_EQ(evaluate_queries("1 / 0\n0 % 0\n2 ^ -1\n"
                               "-123456789012345678901234567890 * 987654321098765432109876543210\n"
                               "1000000000000000000000000000000 - 1\n-3 cmp -2\n"),
              "error\nerror\nerror\n"
              "-121932631137021795226185032733622923332237463801111263526900\n"
              "999999999999999999999999999999\n-1\n");
}

TEST(Query, EmptyInputAndMissingFinalNewline) {
    EXPECT_EQ(evaluate_queries(""), "");
    EXPECT_EQ(evaluate_queries("1 + 1"), "2\n");
}

TEST(Query, ZeroExponentForms) {
    EXPECT_EQ(evaluate_query("5 ^ -0"), "1");
    EXPECT_EQ(evaluate_query("-0 ^ -00"), "1");
    EXPECT_EQ(evaluate_query("5 / -0"), "error");
    EXPECT_EQ(evaluate_query("5 % -000"), "error");
    EXPECT_EQ(evaluate_query("5 ^ -1"), "error");
    EXPECT_EQ(evaluate_query("0 ^ 0005"), "0");
}

TEST(Query, NeverNegativeZero) {
    EXPECT_EQ(evaluate_query("-7 % 7"), "0");
    EXPECT_EQ(evaluate_query("-1 / 2"), "0");
    EXPECT_EQ(evaluate_query("-5 * 0"), "0");
    EXPECT_EQ(evaluate_query("-5 + 5"), "0");
}

TEST(Query, PowerSigns) {
    EXPECT_EQ(evaluate_query("-2 ^ 3"), "-8");
    EXPECT_EQ(evaluate_query("-2 ^ 2"), "4");
    EXPECT_EQ(evaluate_query("-1 ^ 999"), "-1");
    EXPECT_EQ(evaluate_query("-1 ^ 5000"), "1");
}

TEST(Query, CompareWithLeadingZerosAndSigns) {
    EXPECT_EQ(evaluate_query("-0 cmp 0"), "0");
    EXPECT_EQ(evaluate_query("-5 cmp 3"), "-1");
    EXPECT_EQ(evaluate_query("10 cmp 9"), "1");
    EXPECT_EQ(evaluate_query("-10 cmp -9"), "-1");
}

TEST(Query, LargeOperands) {
    const std::string nines(50000, '9');
    // (10^n - 1)^2 = 10^2n - 2*10^n + 1 = 99..98 00..01
    const std::string expect = std::string(49999, '9') + "8" + std::string(49999, '0') + "1";
    EXPECT_EQ(evaluate_query(nines + " * " + nines), expect);
    EXPECT_EQ(evaluate_query(expect + " / " + nines), nines);
    EXPECT_EQ(evaluate_query(expect + " % " + nines), "0");
}

TEST(Query, Malformed) {
    EXPECT_THROW(evaluate_query("1 +"), bigint::ParseError);
    EXPECT_THROW(evaluate_query("1 ? 2"), bigint::ParseError);
    EXPECT_THROW(evaluate_query("x + 2"), bigint::ParseError);
}
