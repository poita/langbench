#include <gtest/gtest.h>

#include "sitegen/value.hpp"

using namespace sitegen;

TEST(Value, DefaultIsUndefined) {
  EXPECT_TRUE(Value().is_undefined());
  EXPECT_TRUE(Value::undefined().is_undefined());
  EXPECT_TRUE(Value::none().is_none());
}

TEST(Value, KindsAndAccessors) {
  EXPECT_EQ(Value::integer(-3).as_int(), -3);
  EXPECT_EQ(Value::real(1.5).as_float(), 1.5);
  EXPECT_TRUE(Value::boolean(true).as_bool());
  EXPECT_EQ(Value::string("hi").as_string(), "hi");
  EXPECT_EQ(Value::list({Value::integer(1)}).as_list().size(), 1u);
  EXPECT_TRUE(Value::boolean(false).is_number());
  EXPECT_FALSE(Value::string("1").is_number());
}

TEST(Value, CopiesShareStorage) {
  const Value a = Value::string(std::string(1000, 'x'));
  const Value b = a;
  EXPECT_EQ(&a.as_string(), &b.as_string());
}

TEST(Dict, KeepsInsertionOrderAndReplacesInPlace) {
  Dict d;
  d.set("b", Value::integer(1));
  d.set("a", Value::integer(2));
  d.set("b", Value::integer(3));
  ASSERT_EQ(d.size(), 2u);
  EXPECT_EQ(d.entries()[0].first, "b");
  EXPECT_EQ(d.find("b")->as_int(), 3);
  EXPECT_EQ(d.find("a")->as_int(), 2);
  EXPECT_EQ(d.find("zzz"), nullptr);
}

TEST(Dict, LookupStillWorksOnceTheIndexIsBuilt) {
  Dict d;
  for (int i = 0; i < 100; ++i) d.set("k" + std::to_string(i), Value::integer(i));
  d.set("k50", Value::integer(-1));
  EXPECT_EQ(d.size(), 100u);
  EXPECT_EQ(d.find("k99")->as_int(), 99);
  EXPECT_EQ(d.find("k50")->as_int(), -1);
  EXPECT_EQ(d.find("k100"), nullptr);
  EXPECT_EQ(d.entries()[50].first, "k50");
}

TEST(FormatFloat, PositionalAndScientific) {
  EXPECT_EQ(format_float(3.0), "3.0");
  EXPECT_EQ(format_float(0.5), "0.5");
  EXPECT_EQ(format_float(1000000000000000.0), "1000000000000000.0");
  EXPECT_EQ(format_float(0.0001), "0.0001");
  EXPECT_EQ(format_float(0.1 + 0.2), "0.30000000000000004");
  EXPECT_EQ(format_float(1e16), "1e+16");
  EXPECT_EQ(format_float(0.00001), "1e-05");
  EXPECT_EQ(format_float(1.5e300), "1.5e+300");
  EXPECT_EQ(format_float(-2.5), "-2.5");
  EXPECT_EQ(format_float(123456.789), "123456.789");
}

TEST(FormatFloat, Zeros) {
  EXPECT_EQ(format_float(0.0), "0.0");
  EXPECT_EQ(format_float(-0.0), "-0.0");
}

TEST(Display, ScalarsPrintLikeJinja) {
  EXPECT_EQ(to_display_string(Value::boolean(true)), "True");
  EXPECT_EQ(to_display_string(Value::boolean(false)), "False");
  EXPECT_EQ(to_display_string(Value::none()), "None");
  EXPECT_EQ(to_display_string(Value::integer(-12)), "-12");
  EXPECT_EQ(to_display_string(Value::string("a<b")), "a<b");
}

TEST(Display, ListsAndDictsUseRepr) {
  Dict inner;
  inner.set("k", Value::list({Value::real(2.0)}));
  const Value v = Value::list({Value::integer(1), Value::string("a"), Value::boolean(true), Value::none(),
                               Value::real(1.5), Value::string("it's"), Value::dict(inner)});
  EXPECT_EQ(to_display_string(v), "[1, 'a', True, None, 1.5, \"it's\", {'k': [2.0]}]");
  EXPECT_EQ(to_display_string(Value::list({})), "[]");
  EXPECT_EQ(to_display_string(Value::dict(Dict())), "{}");
}

TEST(Display, ReprEscapesStrings) {
  EXPECT_EQ(repr(Value::string("a\\b\nc\td\re")), "'a\\\\b\\nc\\td\\re'");
  EXPECT_EQ(repr(Value::string("both ' and \"")), "'both \\' and \"'");
}

TEST(Equality, NumbersCompareNumerically) {
  EXPECT_TRUE(values_equal(Value::integer(1), Value::real(1.0)));
  EXPECT_TRUE(values_equal(Value::boolean(true), Value::integer(1)));
  EXPECT_FALSE(values_equal(Value::integer(1), Value::string("1")));
  EXPECT_FALSE(values_equal(Value::none(), Value::integer(0)));
  EXPECT_TRUE(values_equal(Value::none(), Value::none()));
}

TEST(Equality, ListsAndDictsAreStructural) {
  EXPECT_TRUE(values_equal(Value::list({Value::integer(1), Value::string("a")}),
                           Value::list({Value::real(1.0), Value::string("a")})));
  EXPECT_FALSE(values_equal(Value::list({Value::integer(1)}), Value::list({})));
  Dict a, b;
  a.set("x", Value::integer(1));
  a.set("y", Value::integer(2));
  b.set("y", Value::integer(2));
  b.set("x", Value::integer(1));
  EXPECT_TRUE(values_equal(Value::dict(a), Value::dict(b)));
  b.set("z", Value::integer(3));
  EXPECT_FALSE(values_equal(Value::dict(a), Value::dict(b)));
}
