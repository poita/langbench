#include <gtest/gtest.h>

#include "jq/jq.hpp"

using jq::parse_json;
using jq::to_json;

TEST(JsonParse, Scalars) {
  EXPECT_TRUE(parse_json("null").is_null());
  EXPECT_EQ(parse_json("true").type(), jq::Type::True);
  EXPECT_EQ(parse_json("false").type(), jq::Type::False);
  EXPECT_EQ(parse_json("-12").number(), -12);
  EXPECT_EQ(parse_json("0.125").number(), 0.125);
  EXPECT_EQ(parse_json("1e3").number(), 1000);
  EXPECT_EQ(parse_json("  7 \n").number(), 7);
}

TEST(JsonParse, NumbersAreCorrectlyRounded) {
  EXPECT_EQ(parse_json("3086419725308.5").number(), 3086419725308.5);
  EXPECT_EQ(parse_json("0.1").number(), 0.1);
  EXPECT_EQ(parse_json("9007199254740991").number(), 9007199254740991.0);
}

TEST(JsonParse, StringEscapes) {
  EXPECT_EQ(parse_json(R"("a\"\\\/\b\f\n\r\t")").string(), "a\"\\/\b\f\n\r\t");
  EXPECT_EQ(parse_json(R"("\u00e9\u00E9")").string(), "\xC3\xA9\xC3\xA9");
  EXPECT_EQ(parse_json(R"("\ud83d\ude00")").string(), "\xF0\x9F\x98\x80");
  EXPECT_EQ(parse_json("\"\xC3\xA9\"").string(), "\xC3\xA9");
}

TEST(JsonParse, ObjectsKeepDocumentOrder) {
  jq::Value v = parse_json(R"({"z":1,"a":{"y":[1,2],"b":null}})");
  EXPECT_EQ(to_json(v), R"({"z":1,"a":{"y":[1,2],"b":null}})");
}

TEST(JsonParse, Errors) {
  for (const char* bad : {"", "[", "{\"a\"}", "[1,]", "tru", "01x", "\"abc", "[1] 2", "{\"a\":1,}",
                          "-", "1.", "\"\\x\""})
    EXPECT_THROW(parse_json(bad), jq::JsonError) << bad;
}

TEST(JsonWrite, StringEscaping) {
  EXPECT_EQ(to_json(jq::Value::string("a\"\\\b\f\n\r\t")), R"("a\"\\\b\f\n\r\t")");
  EXPECT_EQ(to_json(jq::Value::string(std::string("\x01\x1f\x7f", 3))), R"("\u0001\u001f\u007f")");
  EXPECT_EQ(to_json(jq::Value::string("/<>&\xC3\xA9")), "\"/<>&\xC3\xA9\"");
}

TEST(JsonWrite, Numbers) {
  EXPECT_EQ(to_json(jq::Value::number(3)), "3");
  EXPECT_EQ(to_json(jq::Value::number(-12)), "-12");
  EXPECT_EQ(to_json(jq::Value::number(1000000000000.0)), "1000000000000");
  EXPECT_EQ(to_json(jq::Value::number(1.5)), "1.5");
  EXPECT_EQ(to_json(jq::Value::number(0.125)), "0.125");
  EXPECT_EQ(to_json(jq::Value::number(3086419725308.5)), "3086419725308.5");
  EXPECT_EQ(to_json(jq::Value::number(0.1 + 0.2)), "0.30000000000000004");
  EXPECT_EQ(to_json(jq::Value::number(9007199254740991.0)), "9007199254740991");
}

TEST(JsonWrite, RoundTrip) {
  const char* docs[] = {"[]", "{}", "[1,2.5,\"x\",null,true,false,{\"a\":[{}]}]",
                        R"({"k":"v","n":{"m":[]}})"};
  for (const char* d : docs) EXPECT_EQ(to_json(parse_json(d)), d);
}
