#include <gtest/gtest.h>

#include "test_util.hpp"

using namespace kiln;

namespace {
std::string parseError(const std::string& src) {
  try {
    parseBuildFile(src, "f.kiln");
  } catch (const Error& e) {
    return e.message();
  }
  return "";
}
}  // namespace

TEST(Parser, ValidFile) {
  EXPECT_EQ(parseError(
                "rule r(a, b = 1) {\n  step {\n    out \"out/{a}\"\n    cmd write(\"x\")\n  }\n}\n"
                "when 1 < 2 {\n} elsewhen true {\n} otherwise {\n}\n"
                "each i, x in [1, 2] {\n}\n"
                "use r(\"a\", b = 2)\n"),
            "");
}

TEST(Parser, LexicalErrorsBeatGrammarErrors) {
  EXPECT_EQ(parseError("let = 1\nlet x = \"abc\n"), "E_PARSE f.kiln:2");
}

TEST(Parser, GrammarErrorsFirstInFileOrder) {
  EXPECT_EQ(parseError("let x = 1\nlet y = 1 2\nlet = 3\n"), "E_PARSE f.kiln:2");
}

TEST(Parser, ErrorsInsideLiteralsAreGrammarErrors) {
  EXPECT_EQ(parseError("let x = \"\\q\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("let x = \"}\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("let x = \"{}\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("let x = \"{ }\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("let x = \"{1 2}\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("let x = \"{{ok}}\"\n"), "");
}

TEST(Parser, UnterminatedBlockReportsInnermostHeader) {
  EXPECT_EQ(parseError("when true {\n  each x in [] {\n"), "E_PARSE f.kiln:2");
  EXPECT_EQ(parseError("when true {\n} otherwise {\n"), "E_PARSE f.kiln:2");
}

TEST(Parser, BlockTerminatorErrors) {
  EXPECT_EQ(parseError("}\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("each x in [] {\n} otherwise {\n}\n"), "E_PARSE f.kiln:2");
  EXPECT_EQ(parseError("when true {\n} otherwise {\n} otherwise {\n}\n"), "E_PARSE f.kiln:3");
  EXPECT_EQ(parseError("when true {\n} otherwise {\n} elsewhen true {\n}\n"), "E_PARSE f.kiln:3");
  EXPECT_EQ(parseError("when true {\n} foo\n"), "E_PARSE f.kiln:2");
  EXPECT_EQ(parseError("{\n"), "E_PARSE f.kiln:1");
}

TEST(Parser, ReservedWords) {
  EXPECT_EQ(parseError("let cost = 1\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("let x = out\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("let x = cost(1)\n"), "");   // call names are a separate namespace
  EXPECT_EQ(parseError("let x = 1 |> cost\n"), "");
  EXPECT_EQ(parseError("rule r(in) {\n}\n"), "E_PARSE f.kiln:1");
}

TEST(Parser, StepFieldPlacement) {
  EXPECT_EQ(parseError("out \"out/a\"\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("step {\n  let x = 1\n}\n"), "E_PARSE f.kiln:2");
  EXPECT_EQ(parseError("step {\n  step {\n  }\n}\n"), "E_PARSE f.kiln:2");
}

TEST(Parser, UseArgumentRules) {
  EXPECT_EQ(parseError("use r(a = 1, 2)\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("use r(a == 1)\n"), "");
  EXPECT_EQ(parseError("use r(1,)\n"), "");
}

TEST(Parser, RuleParameterRules) {
  EXPECT_EQ(parseError("rule r(a, a) {\n}\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("rule r(a = 1, b) {\n}\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("rule r(a = 1, b = a,) {\n}\n"), "");
}

TEST(Parser, EachNamesMustDiffer) {
  EXPECT_EQ(parseError("each x, x in [] {\n}\n"), "E_PARSE f.kiln:1");
}

TEST(Parser, CallsOnlyApplyToIdentifiers) {
  EXPECT_EQ(parseError("let x = (f)(1)\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("let x = f(1)(2)\n"), "E_PARSE f.kiln:1");
  EXPECT_EQ(parseError("let x = f(1)[0]\n"), "");
}
