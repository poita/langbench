#include <gtest/gtest.h>

#include "jq/jq.hpp"

using jq::Object;
using jq::ObjectBuilder;
using jq::Value;

namespace {
Value J(const char* text) { return jq::parse_json(text); }
}  // namespace

TEST(Value, DefaultIsNull) {
  Value v;
  EXPECT_TRUE(v.is_null());
  EXPECT_FALSE(v.truthy());
}

TEST(Value, Truthiness) {
  EXPECT_FALSE(Value::boolean(false).truthy());
  EXPECT_TRUE(Value::boolean(true).truthy());
  EXPECT_TRUE(Value::number(0).truthy());
  EXPECT_TRUE(Value::string("").truthy());
  EXPECT_TRUE(J("[]").truthy());
  EXPECT_TRUE(J("{}").truthy());
}

TEST(Value, TypeNames) {
  EXPECT_STREQ(Value().type_name(), "null");
  EXPECT_STREQ(Value::boolean(true).type_name(), "boolean");
  EXPECT_STREQ(Value::number(1).type_name(), "number");
  EXPECT_STREQ(Value::string("x").type_name(), "string");
  EXPECT_STREQ(J("[]").type_name(), "array");
  EXPECT_STREQ(J("{}").type_name(), "object");
}

TEST(Value, CopiesShareStorage) {
  Value a = Value::string("hello");
  Value b = a;
  EXPECT_EQ(&a.string(), &b.string());
}

TEST(Ordering, TypeOrder) {
  Value ordered[] = {Value(), Value::boolean(false), Value::boolean(true), Value::number(-5),
                     Value::string(""), J("[]"), J("{}")};
  for (int i = 0; i < 7; ++i)
    for (int j = 0; j < 7; ++j) EXPECT_EQ(jq::compare(ordered[i], ordered[j]) < 0, i < j);
}

TEST(Ordering, Strings) {
  EXPECT_LT(Value::string(""), Value::string("a"));
  EXPECT_LT(Value::string("a"), Value::string("ab"));
  EXPECT_LT(Value::string("ab"), Value::string("b"));
  EXPECT_LT(Value::string("Z"), Value::string("a"));
  EXPECT_LT(Value::string("z"), Value::string("\xC3\xA9"));
}

TEST(Ordering, Arrays) {
  EXPECT_LT(J("[1]"), J("[1,2]"));
  EXPECT_LT(J("[1,2]"), J("[2]"));
  EXPECT_EQ(J("[1,[2]]"), J("[1,[2]]"));
}

TEST(Ordering, ObjectsIgnoreKeyOrderForEquality) {
  EXPECT_EQ(J(R"({"a":1,"b":2})"), J(R"({"b":2,"a":1})"));
  EXPECT_LT(J(R"({"a":2})"), J(R"({"b":1})"));        // key lists first
  EXPECT_LT(J(R"({"a":1,"b":9})"), J(R"({"a":2,"b":0})"));  // then values
  EXPECT_LT(J(R"({"a":1})"), J(R"({"a":1,"b":1})"));  // prefix of keys sorts first
}

TEST(Ordering, IntegersAndFractionsAreOneType) {
  EXPECT_EQ(Value::number(1), Value::number(1.5 - 0.5));
}

TEST(Object, InsertionOrderAndReplace) {
  ObjectBuilder b;
  b.set("z", Value::number(1));
  b.set("a", Value::number(2));
  b.set("z", Value::number(3));
  Object o = b.build();
  ASSERT_EQ(o.size(), 2u);
  EXPECT_EQ(o.entry(0).key, "z");
  EXPECT_EQ(o.entry(0).value.number(), 3);
  EXPECT_EQ(o.entry(1).key, "a");
}

TEST(Object, LookupOnLargeObjects) {
  ObjectBuilder b;
  for (int i = 0; i < 1000; ++i) b.set("k" + std::to_string(i), Value::number(i));
  Object o = b.build();
  for (int i = 0; i < 1000; ++i) {
    const Value* v = o.find("k" + std::to_string(i));
    ASSERT_NE(v, nullptr);
    EXPECT_EQ(v->number(), i);
  }
  EXPECT_EQ(o.find("nope"), nullptr);
}

TEST(Object, BuilderFromBaseDoesNotMutateBase) {
  Value base = J(R"({"a":1})");
  ObjectBuilder b(base.object());
  b.set("a", Value::number(9));
  b.set("b", Value::number(2));
  Value derived = b.build_value();
  EXPECT_EQ(jq::to_json(base), R"({"a":1})");
  EXPECT_EQ(jq::to_json(derived), R"({"a":9,"b":2})");
}

TEST(Object, SortedKeys) {
  Object o = J(R"({"b":1,"a":2,"B":3})").object();
  std::vector<std::string> expected{"B", "a", "b"};
  EXPECT_EQ(o.sorted_keys(), expected);
  EXPECT_EQ(&o.sorted_order(), &o.sorted_order());  // cached
}
