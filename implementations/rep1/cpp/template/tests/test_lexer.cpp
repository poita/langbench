#include <gtest/gtest.h>

#include "jinjalite/error.hpp"
#include "jinjalite/lexer.hpp"

using namespace jinjalite;

namespace {
void expect_syntax_error(const std::string& src) {
  try {
    lex_template(src);
    FAIL() << "expected a syntax error for: " << src;
  } catch (const Error& e) {
    EXPECT_EQ(e.kind(), ErrorKind::Syntax) << src;
  }
}
}  // namespace

TEST(Lexer, TextAndTags) {
  auto items = lex_template("a{{ x }}b{% if y %}c");
  ASSERT_EQ(items.size(), 5u);
  EXPECT_EQ(items[0].kind, Item::Kind::Text);
  EXPECT_EQ(items[0].text, "a");
  EXPECT_EQ(items[1].kind, Item::Kind::Print);
  EXPECT_TRUE(items[1].tokens[0].is_name("x"));
  EXPECT_EQ(items[3].kind, Item::Kind::Statement);
  EXPECT_EQ(items[3].tokens.size(), 2u);
}

TEST(Lexer, WhitespaceControl) {
  auto items = lex_template("a  \n {{- x -}} \n b {#- c -#} \t d");
  ASSERT_EQ(items.size(), 4u);
  EXPECT_EQ(items[0].text, "a");
  EXPECT_EQ(items[2].text, "b");
  EXPECT_EQ(items[3].text, "d");
}

TEST(Lexer, StripDoesNotCrossTags) {
  auto items = lex_template("{{ a }} {{- b }}");
  ASSERT_EQ(items.size(), 2u);  // the single space is stripped, tags stay
  auto items2 = lex_template("{{ a -}}{# c #} x");
  ASSERT_EQ(items2.size(), 2u);
  EXPECT_EQ(items2[1].text, " x");
}

TEST(Lexer, CloserBeforeMinusOperator) {
  auto items = lex_template("{{ x -}} y");
  ASSERT_EQ(items.size(), 2u);
  EXPECT_EQ(items[1].text, "y");
  EXPECT_EQ(items[0].tokens.size(), 1u);
}

TEST(Lexer, Tokens) {
  auto items = lex_template("{{ 1 2.5 'a\\n' ** // == != <= >= ~ x_1 }}");
  const auto& t = items[0].tokens;
  ASSERT_EQ(t.size(), 11u);
  EXPECT_EQ(t[0].kind, TokenKind::Int);
  EXPECT_EQ(t[0].int_value, 1);
  EXPECT_EQ(t[1].kind, TokenKind::Float);
  EXPECT_DOUBLE_EQ(t[1].float_value, 2.5);
  EXPECT_EQ(t[2].kind, TokenKind::String);
  EXPECT_EQ(t[2].text, "a\n");
  EXPECT_TRUE(t[3].is_op("**"));
  EXPECT_TRUE(t[4].is_op("//"));
  EXPECT_TRUE(t[10].is_name("x_1"));
}

TEST(Lexer, StringMayContainCloser) {
  auto items = lex_template("{% set a = \"%}\" %}");
  EXPECT_EQ(items[0].tokens.size(), 4u);
}

TEST(Lexer, BraceIsTextUnlessOpener) {
  auto items = lex_template("{ } } { x");
  ASSERT_EQ(items.size(), 1u);
  EXPECT_EQ(items[0].text, "{ } } { x");
}

TEST(Lexer, Errors) {
  expect_syntax_error("{{ x");
  expect_syntax_error("{% if x");
  expect_syntax_error("{# never closed");
  expect_syntax_error("{{ 'abc }}");
  expect_syntax_error("{{ 'a\\q' }}");
  expect_syntax_error("{{ @ }}");
  expect_syntax_error("{{{ x }}}");
  expect_syntax_error("{{ x %}");
}

TEST(Lexer, CommentEndsAtFirstCloser) {
  auto items = lex_template("a{# x {# y #}b");
  ASSERT_EQ(items.size(), 2u);
  EXPECT_EQ(items[1].text, "b");
}
