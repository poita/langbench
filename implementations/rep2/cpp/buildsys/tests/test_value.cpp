#include <gtest/gtest.h>

#include "test_util.hpp"

using namespace kiln;

namespace {
Value S(const char* s) { return Value::string(s); }
Value I(std::int64_t i) { return Value::integer(i); }
Value L(Value::List l) { return Value::list(std::move(l)); }
}  // namespace

TEST(Value, TotalOrderAcrossTypes) {
  EXPECT_LT(compare(Value::boolean(true), I(0)), 0);
  EXPECT_LT(compare(I(100), S("")), 0);
  EXPECT_LT(compare(S("zzz"), L({})), 0);
  EXPECT_LT(compare(Value::boolean(false), Value::boolean(true)), 0);
}

TEST(Value, StringsAreByteOrdered) {
  EXPECT_LT(compare(S("a"), S("ab")), 0);
  EXPECT_LT(compare(S("Z"), S("a")), 0);
  EXPECT_LT(compare(S("a"), S("\xc3\xa9")), 0);  // bytes >= 0x80 sort after ASCII
}

TEST(Value, ListsCompareElementwise) {
  EXPECT_LT(compare(L({I(1), I(2)}), L({I(1), I(3)})), 0);
  EXPECT_LT(compare(L({I(1)}), L({I(1), I(0)})), 0);
  EXPECT_EQ(compare(L({L({I(1)})}), L({L({I(1)})})), 0);
}

TEST(Value, EqualityIsDeepAndTyped) {
  EXPECT_TRUE(equal(L({S("a"), I(1)}), L({S("a"), I(1)})));
  EXPECT_FALSE(equal(I(1), Value::boolean(true)));
  EXPECT_FALSE(equal(S("1"), I(1)));
  EXPECT_EQ(hashValue(L({S("a")})), hashValue(L({S("a")})));
}

TEST(Value, CopyingSharesPayload) {
  Value a = S("hello");
  Value b = a;
  EXPECT_EQ(&a.asStr(), &b.asStr());
}

TEST(Value, ToText) {
  EXPECT_EQ(toText(I(-5)), "-5");
  EXPECT_EQ(toText(Value::boolean(true)), "true");
  EXPECT_EQ(toText(S("x")), "x");
}
