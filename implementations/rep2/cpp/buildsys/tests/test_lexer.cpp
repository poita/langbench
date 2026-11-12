#include <gtest/gtest.h>

#include "test_util.hpp"

using namespace kiln;

namespace {
std::string lexError(const std::string& src) {
  try {
    lexBuildFile(src, "f.kiln");
  } catch (const Error& e) {
    return e.message();
  }
  return "";
}
}  // namespace

TEST(Lexer, StripsCommentsOutsideStrings) {
  auto lines = lexBuildFile("let x = \"a#b\" # comment\n# whole line\nlet y = 'c#d'\n", "f");
  ASSERT_EQ(lines.size(), 2u);
  EXPECT_EQ(lines[0].tokens.back().text, "a#b");
  EXPECT_EQ(lines[1].line, 3);
}

TEST(Lexer, JoinsLinesByBracketDepth) {
  auto lines = lexBuildFile("let x = f(\n  1,\n  2\n)\nlet y = 1\n", "f");
  ASSERT_EQ(lines.size(), 2u);
  EXPECT_EQ(lines[0].line, 1);
  EXPECT_EQ(lines[1].line, 5);
}

TEST(Lexer, InterpolationBracketsDoNotCount) {
  auto lines = lexBuildFile("let x = \"{f(1}\"\n", "f");  // lone '(' inside a literal
  EXPECT_EQ(lines.size(), 1u);
}

TEST(Lexer, NestedLiteralInsideInterpolation) {
  auto lines = lexBuildFile("cmd write(\"{join(xs, \", \")}\\n\")\n", "f");
  ASSERT_EQ(lines.size(), 1u);
  // cmd write ( "<str>" )
  EXPECT_EQ(lines[0].tokens.size(), 5u);
}

TEST(Lexer, LongestMatchOperators) {
  auto toks = tokenize("a |> b || c ++ d <= e != f");
  std::vector<std::string> got;
  for (auto& t : toks) got.push_back(t.text);
  EXPECT_EQ(got, (std::vector<std::string>{"a", "|>", "b", "||", "c", "++", "d", "<=", "e", "!=", "f"}));
}

TEST(Lexer, ErrorsReportFirstLineOfLogicalLine) {
  EXPECT_EQ(lexError("let b = f(\n  \"unterminated\n)\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(lexError("x = )\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(lexError("\n\nlet x = (1,\n2\n"), "E_PARSE f.kiln:3");
  EXPECT_EQ(lexError("let x = 1 | 2\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(lexError("let x = 1 & 2\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(lexError("let x = $\n"), "E_PARSE f.kiln:1");
}

TEST(Lexer, LiteralsMayNotSpanLines) {
  EXPECT_EQ(lexError("let x = 'abc\n'\n"), "E_PARSE f.kiln:1");
}

TEST(Lexer, SingleQuoteEscapes) {
  EXPECT_EQ(lexError("let x = 'it''s'\n"), "");
}
