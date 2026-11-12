// decode(encode(x)) == x for assorted documents.
#include <gtest/gtest.h>

#include "toml/parser.hpp"
#include "toml/tagged_json.hpp"
#include "toml/writer.hpp"

namespace {
void expect_roundtrip(const std::string& doc) {
  toml::Value first = toml::parse(doc);
  std::string text = toml::to_toml(first);
  toml::Value second = toml::parse(text);
  EXPECT_EQ(toml::to_tagged_json(first), toml::to_tagged_json(second)) << text;
  // Through JSON as well.
  toml::Value via_json = toml::from_tagged_json(toml::to_tagged_json(first));
  EXPECT_EQ(toml::to_toml(via_json), text);
}
}  // namespace

TEST(RoundTrip, Scalars) {
  expect_roundtrip(
      "a = 1\nb = -0.0\nc = 6.626e-34\nd = inf\ne = -nan\nf = 0xFF\ng = 'raw \\n'\n"
      "h = \"\\u0000\\u007f\\t\\\"\"\ni = 1979-05-27T07:32:00.500-00:00\nj = 07:32:00\nk = 1979-05-27\n"
      "l = 1979-05-27 07:32:00z\nm = 5e-324\nn = 1e308\n");
}

TEST(RoundTrip, Structure) {
  expect_roundtrip(
      "x.y.z = 1\n[a]\nb = [1, 'two', [3.0], {c = 4}]\n[a.d]\n[[e]]\nf = 1\n[e.g]\nh = 2\n[[e]]\n"
      "[[e.i]]\nj = 3\n[\"quoted key\".'lit']\n\"\" = 1\n[empty]\n");
}

TEST(RoundTrip, TableWithTypeAndValueKeys) {
  expect_roundtrip("[t]\ntype = \"string\"\nvalue = \"x\"\n");
  expect_roundtrip("t = {type = 'integer', value = '1'}\n");
}

TEST(RoundTrip, EmptyAndInlineEmptyTables) {
  expect_roundtrip("");
  expect_roundtrip("a = {}\nb = []\nc = [[], [{}]]\n");
}
