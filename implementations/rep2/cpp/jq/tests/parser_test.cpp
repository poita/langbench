#include <gtest/gtest.h>

#include "jq/filter.hpp"

using jq::Filter;
using jq::SyntaxError;

TEST(FilterParse, AcceptsTheSubset) {
  for (const char* ok : {
           ".", ".a", ".a.b.c", ".\"a b\"", ".[0]", ".[1:2]", ".[:2]", ".[1:]", ".[]", ".a?", ".[]?",
           "1, 2 | . + 1", "[.[] | select(. > 1)]", "{a, \"b\", $x, (.k): 1, c: .a | .b}", "-.a", "- 1", "2 * -3",
           "if . then 1 elif . == 2 then 3 else 4 end", "if . then 1 end", ". as $x | $x", "reduce .[] as $x (0; . + $x)",
           "(1,2)?", "[.[] | tonumber?]", "has(\"a\")", "error(\"x\")", "1 as $x | 2 as $y | [$x, $y]",
           ".a as $x | .b as $y | $x + $y", "\"a\\u00e9\\n\"", "{}", "[]", "empty", "1.5 + 0.25"})
    EXPECT_NO_THROW(Filter::compile(ok)) << ok;
}

TEST(FilterParse, RejectsMalformedPrograms) {
  for (const char* bad : {"", "[", ".a |", "if . then 1", "{a:}", "foo(1)", "1 +", ")", "\"abc", ". as x | 1", "$"})
    EXPECT_THROW(Filter::compile(bad), SyntaxError) << bad;
}
