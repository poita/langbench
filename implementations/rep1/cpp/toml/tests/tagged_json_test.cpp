#include <gtest/gtest.h>

#include "toml/parser.hpp"
#include "toml/tagged_json.hpp"

using toml::from_tagged_json;
using toml::JsonError;
using toml::to_tagged_json;
using toml::Value;

TEST(TaggedJsonWrite, CompactAndSorted) {
  Value::Table t;
  t.emplace("b", Value::integer(2));
  t.emplace("a", Value::array({Value::boolean(true), Value::string("x")}));
  EXPECT_EQ(to_tagged_json(Value::table(std::move(t))),
            R"({"a":[{"type":"bool","value":"true"},{"type":"string","value":"x"}],)"
            R"("b":{"type":"integer","value":"2"}})");
  EXPECT_EQ(to_tagged_json(Value()), "{}");
}

TEST(TaggedJsonWrite, StringEscaping) {
  Value::Table t;
  t.emplace("k", Value::string(std::string("\"\\\b\f\n\r\t\x01\x1f\x7f\xC3\xA9\xF0\x9F\x98\x80", 16)));
  EXPECT_EQ(to_tagged_json(Value::table(std::move(t))),
            "{\"k\":{\"type\":\"string\",\"value\":\"\\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u001f\x7f\xC3\xA9\xF0\x9F\x98\x80\"}}");
}

TEST(TaggedJsonWrite, TableWithTypeAndValueKeys) {
  Value v = toml::parse("[t]\ntype = \"string\"\nvalue = \"x\"");
  Value back = from_tagged_json(to_tagged_json(v));
  EXPECT_EQ(back, v);
  EXPECT_TRUE(back.find("t")->is_table());
}

TEST(TaggedJsonRead, AnyWhitespaceAndOrder) {
  Value v = from_tagged_json(" {\n \"b\" : { \"value\" : \"1\" , \"type\" : \"integer\" },\n"
                             "\"a\":[ ] , \"c\" : { } }\n");
  EXPECT_EQ(v.find("b")->as_integer(), 1);
  EXPECT_TRUE(v.find("a")->is_array());
  EXPECT_TRUE(v.find("c")->is_table());
  EXPECT_TRUE(v.find("c")->members().empty());
}

TEST(TaggedJsonRead, Escapes) {
  Value v = from_tagged_json(
      R"({"k":{"type":"string","value":"a\u00e9\ud83d\ude00\n\"\\\/\u0000"}})");
  EXPECT_EQ(v.find("k")->as_string(), std::string("a\xC3\xA9\xF0\x9F\x98\x80\n\"\\/") + std::string(1, '\0'));
}

TEST(TaggedJsonRead, DistinguishesTablesFromValues) {
  // Members named type/value whose values are nodes, not strings: a table.
  Value v = from_tagged_json(
      R"({"t":{"type":{"type":"string","value":"x"},"value":{"type":"string","value":"y"}}})");
  ASSERT_TRUE(v.find("t")->is_table());
  EXPECT_EQ(v.find("t")->find("type")->as_string(), "x");
  // An unknown type name makes it a table, whose members must be nodes.
  EXPECT_THROW(from_tagged_json(R"({"t":{"type":"nope","value":"y"}})"), JsonError);
}

TEST(TaggedJsonRead, Malformed) {
  EXPECT_THROW(from_tagged_json(""), JsonError);
  EXPECT_THROW(from_tagged_json("[]"), JsonError);
  EXPECT_THROW(from_tagged_json("{"), JsonError);
  EXPECT_THROW(from_tagged_json(R"({"a":1})"), JsonError);
  EXPECT_THROW(from_tagged_json(R"({"a":"x"})"), JsonError);
  EXPECT_THROW(from_tagged_json(R"({} x)"), JsonError);
  EXPECT_THROW(from_tagged_json(R"({"a":"\q"})"), JsonError);
}
