#include <gtest/gtest.h>

#include "minisql/lexer.hpp"

using namespace minisql;

TEST(Lexer, KeywordsAndIdentifiersAreCaseInsensitive) {
  auto t = tokenize("SeLeCt Emp");
  ASSERT_EQ(t.size(), 2u);
  EXPECT_EQ(t[0].kind, TokenKind::Keyword);
  EXPECT_EQ(t[0].text, "SELECT");
  EXPECT_EQ(t[1].kind, TokenKind::Identifier);
  EXPECT_EQ(t[1].text, "emp");
}

TEST(Lexer, AggregateNamesAreIdentifiers) {
  EXPECT_EQ(tokenize("count")[0].kind, TokenKind::Identifier);
}

TEST(Lexer, OperatorsLongestMatch) {
  auto t = tokenize("<= <> != == < =");
  std::vector<std::string> texts;
  for (auto& tok : t) texts.push_back(tok.text);
  EXPECT_EQ(texts, (std::vector<std::string>{"<=", "<>", "!=", "==", "<", "="}));
}

TEST(Lexer, StringEscapesAndComments) {
  auto t = tokenize("'it''s' -- ignored ; 'x'\n 5");
  ASSERT_EQ(t.size(), 2u);
  EXPECT_EQ(t[0].kind, TokenKind::String);
  EXPECT_EQ(t[0].text, "it's");
  EXPECT_EQ(t[1].text, "5");
}

TEST(Lexer, DoubleMinusIsAComment) {
  EXPECT_TRUE(tokenize("--5").empty());
}

TEST(Lexer, InvalidTokens) {
  EXPECT_EQ(tokenize("\"x\"")[0].kind, TokenKind::Invalid);
  auto t = tokenize("select 'abc; select 1;");
  EXPECT_EQ(t.back().kind, TokenKind::Invalid);
}

TEST(Lexer, DecimalPointIsSeparateToken) {
  EXPECT_EQ(tokenize("1.5").size(), 3u);
}

TEST(Lexer, SplitStatements) {
  auto tokens = tokenize(";; select 1; ; select 2");
  auto ranges = split_statements(tokens);
  ASSERT_EQ(ranges.size(), 2u);
  EXPECT_EQ(ranges[0].second - ranges[0].first, 2u);
}
