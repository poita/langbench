#include <gtest/gtest.h>

#include "sitegen/toml.hpp"

using namespace sitegen::toml;

TEST(Toml, ParsesTheSpecExample) {
  const Document d = parse(
      "# a comment\n"
      "title  = \"The \\\"Big\\\" Blog\"        # trailing comment\n"
      "posts_per_page = 5\n"
      "draft = false\n"
      "tags = [\"one\", \"two\",]\n"
      "motto = \"line one\\nline two\"\n");
  ASSERT_EQ(d.entries().size(), 5u);
  EXPECT_EQ(d.get_string("title"), "The \"Big\" Blog");
  EXPECT_EQ(d.get_integer("posts_per_page"), 5);
  EXPECT_FALSE(d.get_boolean("draft", true));
  EXPECT_EQ(d.get_array("tags"), (std::vector<std::string>{"one", "two"}));
  EXPECT_EQ(d.get_string("motto"), "line one\nline two");
}

TEST(Toml, KeepsEntriesInFileOrder) {
  const Document d = parse("b = 1\na = 2\nc = 3");
  ASSERT_EQ(d.entries().size(), 3u);
  EXPECT_EQ(d.entries()[0].key, "b");
  EXPECT_EQ(d.entries()[1].key, "a");
  EXPECT_EQ(d.entries()[2].key, "c");
}

TEST(Toml, BlankAndCommentLinesAreIgnored) {
  const Document d = parse("\n  \t \n   # c\n\tx = 1\n");
  ASSERT_EQ(d.entries().size(), 1u);
  EXPECT_EQ(d.get_integer("x"), 1);
}

TEST(Toml, HashInsideAStringIsNotAComment) {
  const Document d = parse("a = \"x # y\" # real comment\n");
  EXPECT_EQ(d.get_string("a"), "x # y");
}

TEST(Toml, IntegerForms) {
  const Document d = parse("a = 0\nb = -4\nc = 123\nd = -9223372036854775808\ne = 9223372036854775807");
  EXPECT_EQ(d.get_integer("a", 9), 0);
  EXPECT_EQ(d.get_integer("b"), -4);
  EXPECT_EQ(d.get_integer("c"), 123);
  EXPECT_EQ(d.get_integer("d"), INT64_MIN);
  EXPECT_EQ(d.get_integer("e"), INT64_MAX);
}

TEST(Toml, StringEscapes) {
  const Document d = parse("a = \"\\\\ \\\" \\n \\t \\r \\u00e9 \\u20AC\"");
  EXPECT_EQ(d.get_string("a"), "\\ \" \n \t \r \xC3\xA9 \xE2\x82\xAC");
}

TEST(Toml, NonAsciiAndSingleQuotesStandForThemselves) {
  const Document d = parse("a = \"caf\xC3\xA9 'q'\"");
  EXPECT_EQ(d.get_string("a"), "caf\xC3\xA9 'q'");
}

TEST(Toml, ArraysAllowWhitespaceAndTrailingComma) {
  const Document d = parse("a = [ ]\nb = [\"x\"]\nc = [ \"x\" ,\t\"y\" , ]");
  EXPECT_TRUE(d.get_array("a").empty());
  EXPECT_EQ(d.get_array("b"), std::vector<std::string>{"x"});
  EXPECT_EQ(d.get_array("c"), (std::vector<std::string>{"x", "y"}));
}

TEST(Toml, ValueTypesAreReported) {
  const Document d = parse("s = \"x\"\ni = 1\nb = true\na = []");
  EXPECT_EQ(d.find("s")->type(), Value::Type::String);
  EXPECT_EQ(d.find("i")->type(), Value::Type::Integer);
  EXPECT_EQ(d.find("b")->type(), Value::Type::Boolean);
  EXPECT_EQ(d.find("a")->type(), Value::Type::Array);
  EXPECT_EQ(d.find("missing"), nullptr);
}

TEST(Toml, RejectsInvalidLines) {
  EXPECT_THROW(parse("[table]"), ParseError);
  EXPECT_THROW(parse("a"), ParseError);
  EXPECT_THROW(parse("a = "), ParseError);
  EXPECT_THROW(parse("a = \"unterminated"), ParseError);
  EXPECT_THROW(parse("a = \"bad \\q escape\""), ParseError);
  EXPECT_THROW(parse("a = 01"), ParseError);
  EXPECT_THROW(parse("a = 1 2"), ParseError);
  EXPECT_THROW(parse("a = [1]"), ParseError);
  EXPECT_THROW(parse("a = truex"), ParseError);
}

TEST(Toml, ParseErrorReportsTheLine) {
  try {
    parse("a = 1\nb = 2\nc");
    FAIL();
  } catch (const ParseError& e) {
    EXPECT_EQ(e.line(), 3u);
  }
}

TEST(FrontMatter, SplitsMetaAndBody) {
  const FrontMatter fm = split_front_matter("+++\ntitle = \"T\"\n+++\nbody *text*\n\nmore\n");
  EXPECT_EQ(fm.meta.get_string("title"), "T");
  EXPECT_EQ(fm.body, "body *text*\n\nmore\n");
}

TEST(FrontMatter, ClosingDelimiterAsLastLineGivesEmptyBody) {
  EXPECT_EQ(split_front_matter("+++\na = 1\n+++").body, "");
  EXPECT_EQ(split_front_matter("+++\na = 1\n+++\n").body, "");
}

TEST(FrontMatter, OnlyAWholeLineEndsTheFrontMatter) {
  const FrontMatter fm = split_front_matter("+++\na = \"x+++\"\nb = \"+++ y\"\n+++\n+++\nrest\n");
  EXPECT_EQ(fm.meta.get_string("a"), "x+++");
  EXPECT_EQ(fm.meta.get_string("b"), "+++ y");
  EXPECT_EQ(fm.body, "+++\nrest\n");
}

TEST(FrontMatter, EmptyFrontMatter) {
  const FrontMatter fm = split_front_matter("+++\n+++\nhi");
  EXPECT_TRUE(fm.meta.entries().empty());
  EXPECT_EQ(fm.body, "hi");
}

TEST(FrontMatter, MissingOrUnterminatedThrows) {
  EXPECT_THROW(split_front_matter("title = \"x\"\n"), ParseError);
  EXPECT_THROW(split_front_matter("+++\na = 1\n"), ParseError);
}
