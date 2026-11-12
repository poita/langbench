#include <gtest/gtest.h>

#include "jq/jq.hpp"

TEST(FilterCompile, AcceptsTheSubset) {
  for (const char* src : {
           ".", ".a", ".a.b.c", ".[0]", ".[]", ".[1:2]", ".[:2]", ".[1:]", ".a?", ".[]?",
           "(.a)?", "1 + 2 * 3", "-1", "1 - -1", "[.[] | select(.a > 1)]",
           "if . then 1 elif 2 then 3 else 4 end", "if . then 1 end",
           "reduce .[] as $x (0; . + $x)", ". as $x | $x", ".[] as $x | $x | . + 1",
           "has(\"a\")", "sort_by(.a, .b)", "error(\"x\")", "\"\\u00e9\\ud83d\\ude00\"",
           "1 , 2 | . + 1", ".a == 1 and .b != 2 or .c <= 3"})
    EXPECT_NO_THROW(jq::Filter::compile(src)) << src;
}

TEST(FilterCompile, ObjectConstructionForms) {
  EXPECT_NO_THROW(jq::Filter::compile("{a, \"b\", c: 1, \"d\": 2, (\"e\"): 3, f: .x | .y}"));
  EXPECT_NO_THROW(jq::Filter::compile(". as $x | {$x}"));
}

TEST(FilterCompile, RejectsBadSyntax) {
  for (const char* src : {"", "(", ".a +", "[1", "{a:}", "if 1 then 2", ".[", "1 +* 2", "\"abc",
                          "reduce . as $x (0)", "$"})
    EXPECT_THROW(jq::Filter::compile(src), jq::ParseError) << src;
}

TEST(FilterCompile, UnknownBuiltin) {
  EXPECT_THROW(jq::Filter::compile("frobnicate"), jq::ParseError);
  EXPECT_THROW(jq::Filter::compile("length(1)"), jq::ParseError);
}

TEST(FilterCompile, DeeplyNestedParentheses) {
  std::string src(64, '(');
  src += ".";
  src += std::string(64, ')');
  EXPECT_EQ(jq::evaluate(src, "1").at(0), "1");
}

TEST(FilterCompile, PipeBindingDoesNotReparse) {
  // Nested parenthesised terms followed by something other than `as` used to
  // be a classic exponential-backtracking trap.
  std::string src;
  for (int i = 0; i < 40; ++i) src += "(1,";
  src += "2";
  for (int i = 0; i < 40; ++i) src += ")";
  EXPECT_NO_THROW(jq::Filter::compile(src));
}
