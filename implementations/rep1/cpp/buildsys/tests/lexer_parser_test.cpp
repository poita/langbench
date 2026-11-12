#include <gtest/gtest.h>

#include "support.hpp"

using namespace kiln;
using testing_support::eval_error;

namespace {
std::string parse_error(const std::string& src) {
  try {
    parse_program(src, "f.kiln");
  } catch (const Error& e) {
    return e.text();
  }
  return {};
}
}  // namespace

TEST(Lexer, LogicalLinesJoinOnBrackets) {
  auto lines = lex("let a = f(\n  1,\n  2)\nlet b = 3\n", "f");
  ASSERT_EQ(lines.size(), 2u);
  EXPECT_EQ(lines[0].line, 1);
  EXPECT_EQ(lines[1].line, 4);
}

TEST(Lexer, CommentsAreStringAware) {
  auto lines = lex("let a = \"x # y\" # comment\n# whole line\n\n  \nlet b = 'it''s # not'\n", "f");
  ASSERT_EQ(lines.size(), 2u);
  EXPECT_EQ(lines[0].tokens.size(), 4u);
  EXPECT_EQ(lines[0].tokens[3].text, "\"x # y\"");
  EXPECT_EQ(lines[1].line, 5);
}

TEST(Lexer, InterpolationMayContainQuotesAndBraces) {
  auto lines = lex("cmd write(\"{join(xs, \", \")}\\n\")\n", "f");
  ASSERT_EQ(lines.size(), 1u);
  EXPECT_EQ(lines[0].tokens.size(), 5u);  // cmd write ( "..." )
}

TEST(Lexer, OperatorsAreLongestFirst) {
  auto toks = tokenize("a |> b || c && d == e != f <= g >= h < i > j ++ k ~ l");
  std::vector<std::string> ops;
  for (const auto& t : toks) {
    if (t.kind == TokenKind::Op) ops.push_back(t.text);
  }
  EXPECT_EQ(ops, (std::vector<std::string>{"|>", "||", "&&", "==", "!=", "<=", ">=", "<", ">", "++", "~"}));
}

TEST(Lexer, ReportsAtFirstPhysicalLineOfGroup) {
  EXPECT_EQ(parse_error("let b = f(\n  \"unterminated\n)\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let a = 1\nlet b = (1\n"), "E_PARSE f.kiln:2");
  EXPECT_EQ(parse_error("let a = 1)\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let a = 1 | 2\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let a = 1 & 2\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let a = 1 $ 2\n"), "E_PARSE f.kiln:1");
}

TEST(Parser, LexicalErrorsBeatEarlierGrammarErrors) {
  EXPECT_EQ(parse_error("let = 1\nlet x = \"abc\n"), "E_PARSE f.kiln:2");
}

TEST(Parser, UnterminatedBlockReportsInnermostHeader) {
  EXPECT_EQ(parse_error("when true {\n  each x in [1] {\n    let a = 1\n"), "E_PARSE f.kiln:2");
  EXPECT_EQ(parse_error("when true {\n} otherwise {\n"), "E_PARSE f.kiln:2");
  // ...but any other error in the file wins over an unterminated block.
  EXPECT_EQ(parse_error("step {\nlet x = 1\n"), "E_PARSE f.kiln:2");
}

TEST(Parser, BlockTerminatorErrors) {
  EXPECT_EQ(parse_error("}\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("each x in [1] {\n} otherwise {\n}\n"), "E_PARSE f.kiln:2");
  EXPECT_EQ(parse_error("when true {\n} otherwise {\n} elsewhen true {\n}\n"), "E_PARSE f.kiln:3");
  EXPECT_EQ(parse_error("when true {\n} otherwise {\n} otherwise {\n}\n"), "E_PARSE f.kiln:3");
  EXPECT_EQ(parse_error("when true {\n} foo\n"), "E_PARSE f.kiln:2");
  EXPECT_EQ(parse_error("{\n"), "E_PARSE f.kiln:1");
}

TEST(Parser, ReservedWords) {
  EXPECT_EQ(parse_error("let cost = 1\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let x = in\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("rule r(out) {\n}\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("each in in [1] {\n}\n"), "E_PARSE f.kiln:1");
  // Reserved words are fine as call names and rule names in `use`.
  EXPECT_EQ(parse_error("let x = 1 |> cost\n"), "");
  EXPECT_EQ(parse_error("use cost()\n"), "");
  EXPECT_EQ(eval_error("let x = 1 |> cost\n"), "E_UNKNOWN_FUNC cost");
  EXPECT_EQ(eval_error("let x = true(1)\n"), "E_UNKNOWN_FUNC true");
}

TEST(Parser, GrammarRules) {
  EXPECT_EQ(parse_error("let x = 1 2\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("out \"x\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("step {\n  let x = 1\n}\n"), "E_PARSE f.kiln:2");
  EXPECT_EQ(parse_error("step {\n  step {\n  }\n}\n"), "E_PARSE f.kiln:2");
  EXPECT_EQ(parse_error("rule r(a = 1, b) {\n}\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("rule r(a, a) {\n}\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("use r(a = 1, 2)\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("each a, a in [1] {\n}\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let x = (f)(1)\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let x = f(1)(2)\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let x = 1 |> 2\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let x = [1, 2,]\nuse r(1, 2,)\nrule q(a, b,) {\n}\n"), "");
}

TEST(Parser, StringLiteralErrors) {
  EXPECT_EQ(parse_error("let x = \"a\\qb\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let x = \"a}b\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let x = \"{}\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let x = \"{ }\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let x = \"{1 2}\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let x = \"{1 $ 2}\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parse_error("let x = \"{{ok}} \\\" \\n \\0\"\nlet y = 'a\\qb{}'\n"), "");
}

TEST(Parser, InterpolationParsedEvenWhenNeverEvaluated) {
  EXPECT_EQ(parse_error("when false {\n  let x = \"{1 +}\"\n}\n"), "E_PARSE f.kiln:2");
}
