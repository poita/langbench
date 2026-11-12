#include <gtest/gtest.h>

#include "jq/value.hpp"

using jq::compare;
using jq::Member;
using jq::ObjectBuilder;
using jq::Value;

TEST(Value, TypesAndTruthiness) {
  EXPECT_TRUE(Value().is_null());
  EXPECT_FALSE(Value().truthy());
  EXPECT_FALSE(Value::boolean(false).truthy());
  EXPECT_TRUE(Value::boolean(true).truthy());
  EXPECT_TRUE(Value::number(0).truthy());
  EXPECT_TRUE(Value::string("").truthy());
  EXPECT_TRUE(Value::array({}).truthy());
  EXPECT_STREQ(Value::boolean(true).type_name(), "boolean");
  EXPECT_STREQ(Value::array({}).type_name(), "array");
}

TEST(Value, CopiesShareStorage) {
  Value a = Value::string("hello");
  Value b = a;
  EXPECT_EQ(&a.as_string(), &b.as_string());
  Value c = std::move(a);
  EXPECT_TRUE(a.is_null());  // NOLINT: moved-from Values are null
  EXPECT_EQ(c.as_string(), "hello");
}

TEST(Value, OrderingAcrossTypes) {
  Value vs[] = {Value(),
                Value::boolean(false),
                Value::boolean(true),
                Value::number(-1),
                Value::string(""),
                Value::array({}),
                ObjectBuilder().build()};
  for (int i = 0; i < 7; ++i)
    for (int j = 0; j < 7; ++j) EXPECT_EQ(compare(vs[i], vs[j]) < 0, i < j) << i << " " << j;
}

TEST(Value, StringOrderIsByCodePoint) {
  EXPECT_LT(compare(Value::string("Z"), Value::string("a")), 0);
  EXPECT_LT(compare(Value::string("z"), Value::string("\xC3\xA9")), 0);
  EXPECT_LT(compare(Value::string("ab"), Value::string("b")), 0);
  EXPECT_LT(compare(Value::string(""), Value::string("a")), 0);
}

TEST(Value, ArrayOrderIsLexicographic) {
  Value a = Value::array({Value::number(1)});
  Value b = Value::array({Value::number(1), Value::number(0)});
  EXPECT_LT(compare(a, b), 0);
  EXPECT_EQ(compare(a, a), 0);
}

TEST(Value, ObjectEqualityIgnoresInsertionOrder) {
  ObjectBuilder x, y;
  x.set("a", Value::number(1));
  x.set("b", Value::number(2));
  y.set("b", Value::number(2));
  y.set("a", Value::number(1));
  EXPECT_EQ(x.build(), y.build());
}

TEST(Value, ObjectOrderComparesKeysBeforeValues) {
  ObjectBuilder x, y;
  x.set("a", Value::number(5));
  y.set("b", Value::number(1));
  EXPECT_LT(compare(x.build(), y.build()), 0);  // key list ["a"] < ["b"]
}

TEST(ObjectBuilder, RepeatedKeyKeepsFirstPositionLastValue) {
  ObjectBuilder b;
  b.set("b", Value::number(1));
  b.set("a", Value::number(2));
  b.set("b", Value::number(3));
  Value v = b.build();
  const auto& m = v.as_object().members();
  ASSERT_EQ(m.size(), 2u);
  EXPECT_EQ(m[0].key, "b");
  EXPECT_EQ(m[0].value.as_number(), 3);
  EXPECT_EQ(m[1].key, "a");
}

TEST(Object, LookupWorksForLargeObjects) {
  ObjectBuilder b;
  for (int i = 0; i < 1000; ++i) b.set("k" + std::to_string(i), Value::number(i));
  Value v = b.build();
  for (int i = 0; i < 1000; ++i) {
    const Value* f = v.as_object().find("k" + std::to_string(i));
    ASSERT_NE(f, nullptr);
    EXPECT_EQ(f->as_number(), i);
  }
  EXPECT_EQ(v.as_object().find("nope"), nullptr);
}

TEST(Object, SortedOrderIsCached) {
  ObjectBuilder b;
  b.set("b", Value());
  b.set("a", Value());
  Value v = b.build();
  const auto& o1 = v.as_object().sorted_order();
  const auto& o2 = v.as_object().sorted_order();
  EXPECT_EQ(&o1, &o2);
  EXPECT_EQ(v.as_object().members()[o1[0]].key, "a");
}
