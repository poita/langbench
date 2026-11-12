#include <gtest/gtest.h>

#include "jsonschema/json.hpp"

using namespace jsonschema;

TEST(Json, ParsesAllTypes) {
  Value v = parse_json(R"({"a":[1,2.5,"x",true,false,null],"b":{}})");
  ASSERT_TRUE(v.is_object());
  const Value* a = v.find("a");
  ASSERT_NE(a, nullptr);
  ASSERT_EQ(a->size(), 6u);
  EXPECT_TRUE(a->items()[0].is_number());
  EXPECT_EQ(a->items()[2].as_string(), "x");
  EXPECT_TRUE(a->items()[3].as_bool());
  EXPECT_TRUE(a->items()[5].is_null());
  EXPECT_TRUE(v.find("b")->is_object());
  EXPECT_EQ(v.find("zzz"), nullptr);
}

TEST(Json, StringEscapes) {
  Value v = parse_json(R"("a\n\t\"\\\/é💩")");
  EXPECT_EQ(v.as_string(), "a\n\t\"\\/\xC3\xA9\xF0\x9F\x92\xA9");
}

TEST(Json, RejectsMalformedDocuments) {
  for (const char* s : {"", "{", "[1,]", "{\"a\"}", "01", "1.", "\"abc", "tru", "[1] 2", "{'a':1}", "\"\x01\""}) {
    EXPECT_THROW(parse_json(s), JsonParseError) << s;
  }
}

TEST(Json, LargeObjectLookupUsesIndex) {
  Value obj = Value::object();
  for (int i = 0; i < 100; ++i) obj.add_member("k" + std::to_string(i), Value::number(Decimal::from_uint(i)));
  Value copy = obj;
  copy.add_member("extra", Value::boolean(true));
  ASSERT_NE(obj.find("k57"), nullptr);
  EXPECT_EQ(obj.find("k57")->as_number(), Decimal::from_uint(57));
  EXPECT_EQ(obj.find("extra"), nullptr);  // copy-on-write: the original index is untouched
  EXPECT_NE(copy.find("extra"), nullptr);
}

TEST(Json, EqualityIsStructural) {
  EXPECT_TRUE(json_equal(parse_json("1"), parse_json("1.0")));
  EXPECT_TRUE(json_equal(parse_json("100"), parse_json("1e2")));
  EXPECT_FALSE(json_equal(parse_json("true"), parse_json("1")));
  EXPECT_FALSE(json_equal(parse_json("0"), parse_json("false")));
  EXPECT_FALSE(json_equal(parse_json("\"1\""), parse_json("1")));
  EXPECT_TRUE(json_equal(parse_json(R"({"a":1,"b":2})"), parse_json(R"({"b":2.0,"a":1})")));
  EXPECT_FALSE(json_equal(parse_json(R"({"a":1})"), parse_json(R"({"a":1,"b":1})")));
  EXPECT_FALSE(json_equal(parse_json("[1,2]"), parse_json("[2,1]")));
}

TEST(Json, HashAgreesWithEquality) {
  EXPECT_EQ(json_hash(parse_json(R"({"a":1,"b":[1.0,2]})")), json_hash(parse_json(R"({"b":[1,2.00],"a":1.0})")));
}

TEST(Json, DumpRoundTrips) {
  const char* text = R"({"a":[1,2.5,"x\n",true,null],"b":{"c":-0.5}})";
  EXPECT_EQ(parse_json(text).dump(), text);
}
