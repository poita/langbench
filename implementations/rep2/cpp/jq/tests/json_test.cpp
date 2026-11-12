#include <gtest/gtest.h>

#include "jq/json.hpp"

using jq::parse_json;
using jq::to_json;

TEST(JsonParse, Scalars) {
  EXPECT_TRUE(parse_json("null").is_null());
  EXPECT_TRUE(parse_json(" true ").truthy());
  EXPECT_FALSE(parse_json("false").truthy());
  EXPECT_EQ(parse_json("-12.5").as_number(), -12.5);
  EXPECT_EQ(parse_json("1e2").as_number(), 100);
  EXPECT_EQ(parse_json("0.1").as_number(), 0.1);
}

TEST(JsonParse, StringEscapes) {
  EXPECT_EQ(parse_json(R"("a\"b\\c\/d\b\f\n\r\t")").as_string(), "a\"b\\c/d\b\f\n\r\t");
  EXPECT_EQ(parse_json(R"("éé")").as_string(), "\xC3\xA9\xC3\xA9");
  EXPECT_EQ(parse_json(R"("😀")").as_string(), "\xF0\x9F\x98\x80");
  EXPECT_EQ(parse_json("\"\xC3\xA9\"").as_string(), "\xC3\xA9");
}

TEST(JsonParse, ObjectsKeepDocumentOrder) {
  auto v = parse_json(R"({"z":1,"a":{"y":[1,2]},"m":null})");
  const auto& m = v.as_object().members();
  ASSERT_EQ(m.size(), 3u);
  EXPECT_EQ(m[0].key, "z");
  EXPECT_EQ(m[1].key, "a");
  EXPECT_EQ(m[2].key, "m");
}

TEST(JsonParse, Whitespace) {
  EXPECT_EQ(to_json(parse_json(" \t\r\n[ 1 ,\n2 ]\n")), "[1,2]");
}

TEST(JsonParse, Errors) {
  for (const char* bad : {"", "[1,", "{\"a\"}", "tru", "[1] 2", "\"abc", "-", "01x", "{1:2}", "[1,]x"})
    EXPECT_THROW(parse_json(bad), jq::JsonError) << bad;
}

TEST(JsonWrite, CompactAndOrdered) {
  EXPECT_EQ(to_json(parse_json(R"({ "b" : [ 1, 2 ], "a" : { } })")), R"({"b":[1,2],"a":{}})");
}

TEST(JsonWrite, StringEscaping) {
  EXPECT_EQ(to_json(jq::Value::string("a\"b\\c\n\t\r\b\f\x01\x1f\x7f/<>&")),
            "\"a\\\"b\\\\c\\n\\t\\r\\b\\f\\u0001\\u001f\\u007f/<>&\"");
  EXPECT_EQ(to_json(jq::Value::string("\xC3\xA9\xF0\x9F\x98\x80")), "\"\xC3\xA9\xF0\x9F\x98\x80\"");
}

TEST(JsonWrite, Numbers) {
  auto s = [](double d) { return to_json(jq::Value::number(d)); };
  EXPECT_EQ(s(3), "3");
  EXPECT_EQ(s(-12), "-12");
  EXPECT_EQ(s(1000000000000), "1000000000000");
  EXPECT_EQ(s(9007199254740991.0), "9007199254740991");
  EXPECT_EQ(s(1.5), "1.5");
  EXPECT_EQ(s(0.125), "0.125");
  EXPECT_EQ(s(3086419725308.5), "3086419725308.5");
  EXPECT_EQ(s(0.1 + 0.2), "0.30000000000000004");
  EXPECT_EQ(s(0.75), "0.75");
}

TEST(JsonRoundTrip, Document) {
  const char* doc = R"({"a":[1,2.5,"x\ny",null,true,false,{"k":{}}],"b":"é"})";
  EXPECT_EQ(to_json(parse_json(doc)), "{\"a\":[1,2.5,\"x\\ny\",null,true,false,{\"k\":{}}],\"b\":\"\xC3\xA9\"}");
}
