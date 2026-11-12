#include <gtest/gtest.h>

#include "toml/tagged_json.hpp"
#include "toml/writer.hpp"

using toml::format_key;
using toml::from_tagged_json;
using toml::quote_basic_string;
using toml::to_toml;

TEST(Writer, KeyFormatting) {
  EXPECT_EQ(format_key("abc_D-9"), "abc_D-9");
  EXPECT_EQ(format_key(""), "\"\"");
  EXPECT_EQ(format_key("a b"), "\"a b\"");
  EXPECT_EQ(format_key("a.b"), "\"a.b\"");
  EXPECT_EQ(format_key("\xC3\xA9"), "\"\xC3\xA9\"");
}

TEST(Writer, StringQuoting) {
  EXPECT_EQ(quote_basic_string("plain"), "\"plain\"");
  EXPECT_EQ(quote_basic_string(std::string("\"\\\b\t\n\f\r\x01\x7f", 9)),
            "\"\\\"\\\\\\b\\t\\n\\f\\r\\u0001\\u007f\"");
  EXPECT_EQ(quote_basic_string("\xC3\xA9\xF0\x9F\x98\x80"), "\"\xC3\xA9\xF0\x9F\x98\x80\"");
}

TEST(Writer, EmptyRoot) { EXPECT_EQ(to_toml(toml::Value()), "\n"); }

TEST(Writer, WorkedExample) {
  auto v = from_tagged_json(
      R"({"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},)"
      R"({"type":"integer","value":"8002"}]},"dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},)"
      R"("fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],)"
      R"("name":{"type":"string","value":"Tom"}})");
  EXPECT_EQ(to_toml(v),
            "dob = 1979-05-27T07:32:00-08:00\nname = \"Tom\"\n\n[db]\nenabled = true\nports = [8001, 8002]\n\n"
            "[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n");
}

TEST(Writer, FirstHeaderHasNoBlankLine) {
  auto v = from_tagged_json(R"({"a":{"b":{"x":{"type":"integer","value":"1"}}}})");
  EXPECT_EQ(to_toml(v), "[a]\n\n[a.b]\nx = 1\n");
}

TEST(Writer, EmptyContainers) {
  auto v = from_tagged_json(R"({"e":{},"arr":[],"t":{"u":{}}})");
  EXPECT_EQ(to_toml(v), "arr = []\n\n[e]\n\n[t]\n\n[t.u]\n");
}

TEST(Writer, MixedArraysStayInline) {
  auto v = from_tagged_json(
      R"({"a":[{"x":{"type":"integer","value":"1"}},{"type":"integer","value":"2"}],"b":[[],[{}]]})");
  EXPECT_EQ(to_toml(v), "a = [{x = 1}, 2]\nb = [[], [{}]]\n");
}

TEST(Writer, QuotedKeysInHeaders) {
  auto v = from_tagged_json(R"({"a b":{"c.d":[{"":{"type":"bool","value":"false"}}]}})");
  EXPECT_EQ(to_toml(v), "[\"a b\"]\n\n[[\"a b\".\"c.d\"]]\n\"\" = false\n");
}

TEST(Writer, KeysInCodePointOrder) {
  auto v = from_tagged_json(
      R"({"\u00e9":{"type":"integer","value":"3"},"a":{"type":"integer","value":"2"},"B":{"type":"integer","value":"1"}})");
  EXPECT_EQ(to_toml(v), "B = 1\na = 2\n\"\xC3\xA9\" = 3\n");
}
