// End-to-end tests of the evaluator through jq::evaluate / Filter.
#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "jq/jq.hpp"

namespace {

using Out = std::vector<std::string>;

Out run(const std::string& filter, const std::string& json = "null") {
  return jq::evaluate(filter, json);
}

/// Outputs produced before an error, plus whether an error happened.
std::pair<Out, bool> run_partial(const std::string& filter, const std::string& json = "null") {
  Out out;
  bool failed = false;
  try {
    jq::Filter::compile(filter).run(jq::parse_json(json),
                                    [&](const jq::Value& v) { out.push_back(jq::to_json(v)); });
  } catch (const jq::RuntimeError&) {
    failed = true;
  }
  return {out, failed};
}

struct Case {
  const char* filter;
  const char* input;
  Out expected;
};

void PrintTo(const Case& c, std::ostream* os) { *os << c.filter << "  <  " << c.input; }

class EvalCases : public ::testing::TestWithParam<Case> {};

std::string CaseName(const ::testing::TestParamInfo<Case>& info) { return std::to_string(info.index); }

TEST_P(EvalCases, Produces) {
  const Case& c = GetParam();
  EXPECT_EQ(run(c.filter, c.input), c.expected) << c.filter;
}

INSTANTIATE_TEST_SUITE_P(
    Paths, EvalCases,
    ::testing::Values(
        Case{".", "{\"b\":1,\"a\":2}", {"{\"b\":1,\"a\":2}"}},
        Case{".a", "{\"a\":3}", {"3"}},
        Case{".missing", "{\"a\":3}", {"null"}},
        Case{".a", "null", {"null"}},
        Case{".\"a b\"", "{\"a b\":1}", {"1"}},
        Case{".[\"a\"]", "{\"a\":1}", {"1"}},
        Case{".[1]", "[1,2,3]", {"2"}},
        Case{".[-1]", "[1,2,3]", {"3"}},
        Case{".[5]", "[1,2,3]", {"null"}},
        Case{".[]", "[1,2]", {"1", "2"}},
        Case{".[]", "{\"b\":1,\"a\":2}", {"1", "2"}},
        Case{".[1:]", "[1,2,3]", {"[2,3]"}},
        Case{".[:-1]", "[1,2,3]", {"[1,2]"}},
        Case{".[2:1]", "[1,2,3]", {"[]"}},
        Case{".[1:3]", "\"h\xC3\xA9llo\"", {"\"\xC3\xA9l\""}},
        Case{".[1:]", "null", {"null"}},
        Case{"([1,2],[3,4])[(0,1)]", "null", {"1", "3", "2", "4"}},
        Case{".a.b.c", "{\"a\":{\"b\":{\"c\":7}}}", {"7"}}), CaseName);

INSTANTIATE_TEST_SUITE_P(
    Optional, EvalCases,
    ::testing::Values(
        Case{".a?", "5", {}},
        Case{"[([1],2,[3])[0]?]", "null", {"[1,3]"}},
        Case{"[(1,[2],3)[]?]", "null", {"[2]"}},
        Case{"[(1,2,error,3)?]", "null", {"[1,2]"}},
        Case{"(.a.b)?", "5", {}},
        Case{"[.[] | tonumber?]", "[\"1\",\"x\",\"2.5\"]", {"[1,2.5]"}},
        Case{".[1:]?", "5", {}},
        Case{"[.[] | .a?]", "[{\"a\":1},5,{\"a\":2}]", {"[1,2]"}},
        Case{".a??", "5", {}}), CaseName);

INSTANTIATE_TEST_SUITE_P(
    Arithmetic, EvalCases,
    ::testing::Values(
        Case{"[(1,2) + (10,20)]", "null", {"[11,12,21,22]"}},
        Case{"null + 1, 1 + null, null + null", "null", {"1", "1", "null"}},
        Case{"\"a\" + \"b\"", "null", {"\"ab\""}},
        Case{"[1] + [2]", "null", {"[1,2]"}},
        Case{"{\"z\":1,\"a\":2} + {\"m\":3,\"z\":9}", "null", {"{\"z\":9,\"a\":2,\"m\":3}"}},
        Case{"{\"a\":{\"b\":1,\"c\":2}} * {\"a\":{\"b\":9},\"d\":1}", "null",
             {"{\"a\":{\"b\":9,\"c\":2},\"d\":1}"}},
        Case{"[1,2,3,2] - [2]", "null", {"[1,3]"}},
        Case{"[1,2,3,4,5,6,7] - [1,3,5,7,9]", "null", {"[2,4,6]"}},
        Case{"\"ab\" * 3, 3 * \"ab\", \"x\" * 0, \"x\" * -1", "null",
             {"\"ababab\"", "\"ababab\"", "\"\"", "null"}},
        Case{"7 / 2, \"a,b,,c\" / \",\", \"\" / \",\", \"abc\" / \"\"", "null",
             {"3.5", "[\"a\",\"b\",\"\",\"c\"]", "[]", "[\"a\",\"b\",\"c\"]"}},
        Case{"-7 % 3, 7 % -3, 5.5 % 2", "null", {"-1", "1", "1"}},
        Case{"-.a, 1 - -1, 2 * -3, 1 -1", "{\"a\":4}", {"-4", "2", "-6", "0"}},
        Case{"1 + 2 * 3 - 4 / 2", "null", {"5"}},
        Case{"1 < 2, 2 <= 2, \"a\" > \"B\", [1] == [1], {\"a\":1} != {\"a\":2}", "null",
             {"true", "true", "true", "true", "true"}},
        Case{"null < false, false < true, true < 0, 0 < \"\", \"\" < [], [] < {}", "null",
             {"true", "true", "true", "true", "true", "true"}}), CaseName);

INSTANTIATE_TEST_SUITE_P(
    Control, EvalCases,
    ::testing::Values(
        Case{"1, 2 | . + 1", "null", {"2", "3"}},
        Case{"false and error, true or error", "null", {"false", "true"}},
        Case{"(true, false) and (true, false)", "null", {"true", "false", "false"}},
        Case{"if . > 1 then \"big\" elif . > 0 then \"small\" else \"zero\" end", "1", {"\"small\""}},
        Case{"if . then 1 end", "false", {"false"}},
        Case{"if (true, false) then 1 else 2 end", "null", {"1", "2"}},
        Case{". as $x | [$x, $x + 1]", "1", {"[1,2]"}},
        Case{"(1, 2) as $x | $x * 10", "null", {"10", "20"}},
        Case{"1 as $x | 2 as $x | $x", "null", {"2"}},
        Case{"reduce .[] as $x (0; . + $x)", "[1,2,3]", {"6"}},
        Case{"reduce (1,2,3) as $x (0; if $x == 2 then empty else . + $x end)", "null", {"3"}},
        Case{"reduce (1,2) as $x ((0,10); . + $x)", "null", {"3", "13"}},
        Case{"reduce .[] as $x (0; (. + $x, . * 10))", "[1,2]", {"0"}},
        Case{"reduce empty as $x (5; . + 1)", "null", {"5"}},
        Case{"[.[] | select(. > 1)]", "[1,2,3]", {"[2,3]"}},
        Case{"empty", "1", {}}), CaseName);

INSTANTIATE_TEST_SUITE_P(
    Construction, EvalCases,
    ::testing::Values(
        Case{"[]", "null", {"[]"}},
        Case{"[1, 2, 3 | . * 2]", "null", {"[2,4,6]"}},
        Case{"{}", "null", {"{}"}},
        Case{"{a:1,b:2,a:3}", "null", {"{\"a\":3,\"b\":2}"}},
        Case{"{a:(1,2), b:(3,4)}", "null",
             {"{\"a\":1,\"b\":3}", "{\"a\":1,\"b\":4}", "{\"a\":2,\"b\":3}", "{\"a\":2,\"b\":4}"}},
        Case{"{a, \"b\"}", "{\"a\":1,\"b\":2,\"c\":3}", {"{\"a\":1,\"b\":2}"}},
        Case{". as $x | {$x}", "5", {"{\"x\":5}"}},
        Case{"{(\"k\" + \"1\"): 1}", "null", {"{\"k1\":1}"}},
        Case{"{a: .x | .y}", "{\"x\":{\"y\":1}}", {"{\"a\":1}"}},
        Case{"{a: -.x}", "{\"x\":1}", {"{\"a\":-1}"}}), CaseName);

INSTANTIATE_TEST_SUITE_P(
    Builtins, EvalCases,
    ::testing::Values(
        Case{"length", "null", {"0"}},
        Case{"length", "-5", {"5"}},
        Case{"length", "\"h\xC3\xA9llo\"", {"5"}},
        Case{"length", "[1,2]", {"2"}},
        Case{"length", "{\"a\":1}", {"1"}},
        Case{"keys", "{\"b\":1,\"a\":2}", {"[\"a\",\"b\"]"}},
        Case{"keys", "[5,6]", {"[0,1]"}},
        Case{"has(\"a\"), has(\"b\")", "{\"a\":1}", {"true", "false"}},
        Case{"has(1), has(1.5), has(2), has(-1)", "[1,2]", {"true", "true", "false", "false"}},
        Case{"has(\"a\")", "null", {"false"}},
        Case{"type", "[]", {"\"array\""}},
        Case{"[.[] | type]", "[null,true,1,\"s\",[],{}]",
             {"[\"null\",\"boolean\",\"number\",\"string\",\"array\",\"object\"]"}},
        Case{"not", "null", {"true"}},
        Case{"add", "[1,2,3]", {"6"}},
        Case{"add", "[]", {"null"}},
        Case{"add", "[\"a\",\"b\"]", {"\"ab\""}},
        Case{"add", "[[1],[2]]", {"[1,2]"}},
        Case{"add", "[{\"a\":1},{\"b\":2},{\"a\":3}]", {"{\"a\":3,\"b\":2}"}},
        Case{"add", "[null,1,null]", {"1"}},
        Case{"add", "{\"x\":1,\"y\":2}", {"3"}},
        Case{"map(. + 1)", "[1,2]", {"[2,3]"}},
        Case{"map(. + 1)", "{\"a\":1}", {"[2]"}},
        Case{"map(.[]?)", "[[1,2],3,[4]]", {"[1,2,4]"}},
        Case{"sort", "[3,\"a\",null,[1],{\"a\":1},true,false,1]",
             {"[null,false,true,1,3,\"a\",[1],{\"a\":1}]"}},
        Case{"sort_by(.a)", "[{\"a\":2,\"i\":0},{\"a\":1,\"i\":1},{\"a\":2,\"i\":2}]",
             {"[{\"a\":1,\"i\":1},{\"a\":2,\"i\":0},{\"a\":2,\"i\":2}]"}},
        Case{"sort_by(.a, .b)", "[{\"a\":1,\"b\":2},{\"a\":1,\"b\":1},{\"a\":0,\"b\":9}]",
             {"[{\"a\":0,\"b\":9},{\"a\":1,\"b\":1},{\"a\":1,\"b\":2}]"}},
        Case{"sort_by(-.n)", "[{\"n\":0},{\"n\":2}]", {"[{\"n\":2},{\"n\":0}]"}},
        Case{"group_by(.k)", "[{\"k\":\"b\",\"v\":1},{\"k\":\"a\",\"v\":2},{\"k\":\"b\",\"v\":3}]",
             {"[[{\"k\":\"a\",\"v\":2}],[{\"k\":\"b\",\"v\":1},{\"k\":\"b\",\"v\":3}]]"}},
        Case{"group_by(.k)", "[]", {"[]"}},
        Case{"unique", "[3,1,3,2,1]", {"[1,2,3]"}},
        Case{"reverse", "[1,2,3]", {"[3,2,1]"}},
        Case{"reverse", "null", {"[]"}},
        Case{"min, max", "[3,1,2]", {"1", "3"}},
        Case{"min, max", "[]", {"null", "null"}},
        Case{"tostring", "\"s\"", {"\"s\""}},
        Case{"tostring", "[1,{\"a\":\"x\"}]", {"\"[1,{\\\"a\\\":\\\"x\\\"}]\""}},
        Case{"tonumber", "\"12\"", {"12"}},
        Case{"tonumber", "\"-2.5\"", {"-2.5"}},
        Case{"tonumber", "7", {"7"}}), CaseName);

TEST(EvalErrors, PartialResultsThenError) {
  auto [out, failed] = run_partial("1, 2, error, 3");
  EXPECT_TRUE(failed);
  EXPECT_EQ(out, (Out{"1", "2"}));
}

TEST(EvalErrors, TypeErrors) {
  for (const char* f : {"1 + \"a\"", "{} - {}", "[] * 2", "1 / 0", "1 % 0", "5 % 0.5", "-\"a\"",
                        "length", ".[]", ".a", ".[0]", "keys", "sort", "tonumber", "reverse",
                        "map(.)", "min", "has(0)", "{(1): 2}", ".[null]", "error(null)", "add"}) {
    const char* input = (std::string(f) == "length") ? "true"
                        : (std::string(f) == "has(0)") ? "{}"
                        : (std::string(f) == "tonumber") ? "\"abc\""
                        : (std::string(f) == "reverse") ? "\"s\""
                        : (std::string(f) == "map(.)" || std::string(f) == "add") ? "5"
                        : (std::string(f) == ".[]" || std::string(f) == ".a" ||
                           std::string(f) == "sort" || std::string(f) == "min" ||
                           std::string(f) == ".[0]" || std::string(f) == "keys")
                              ? "true"
                              : "null";
    EXPECT_TRUE(run_partial(f, input).second) << f;
  }
}

TEST(EvalErrors, ErrorOfEmptyRaisesNothing) {
  auto [out, failed] = run_partial("error(empty), 1");
  EXPECT_FALSE(failed);
  EXPECT_EQ(out, Out{"1"});
}

TEST(EvalErrors, TryOnlyCatchesInnerErrors) {
  EXPECT_TRUE(run_partial("(1,2)? | error").second);
  EXPECT_TRUE(run_partial(".a.b?", "{\"a\":5}").second == false);
  EXPECT_TRUE(run_partial(".a.b?", "5").second);  // error is in `.a`, not `.b`
  auto [out, failed] = run_partial("(.[] | .a.b?)", "[{\"a\":{\"b\":1}},{\"a\":5},3]");
  EXPECT_EQ(out, Out{"1"});
  EXPECT_TRUE(failed);
}

TEST(EvalErrors, DownstreamErrorsPassThroughNestedTry) {
  EXPECT_TRUE(run_partial("((1,2)? | error)?", "null").second == false);
  EXPECT_TRUE(run_partial("(((1)? | error)?, 3)", "null").first == Out{"3"});
  EXPECT_TRUE(run_partial("((1)?, 2) | error").second);
}

TEST(EvalErrors, UnboundedShortCircuit) {
  EXPECT_EQ(run("false and error"), Out{"false"});
  EXPECT_EQ(run("true or error"), Out{"true"});
}

TEST(Filter, ReusableAndCollect) {
  jq::Filter f = jq::Filter::compile(".[] | . * 2");
  auto a = f.collect(jq::parse_json("[1,2]"));
  auto b = f.collect(jq::parse_json("[5]"));
  ASSERT_EQ(a.size(), 2u);
  EXPECT_EQ(a[1].number(), 4);
  EXPECT_EQ(b[0].number(), 10);
}

TEST(Filter, CallbackExceptionsPropagateAndAreNotCaught) {
  jq::Filter f = jq::Filter::compile("(1,2)?");
  EXPECT_THROW(f.run(jq::Value(), [](const jq::Value&) { throw std::logic_error("x"); }),
               std::logic_error);
}

TEST(Filter, LargeReduceStaysFast) {
  std::string json = "[";
  for (int i = 0; i < 20000; ++i) json += (i ? "," : "") + std::to_string(i);
  json += "]";
  EXPECT_EQ(run("reduce .[] as $x (0; . + $x)", json), Out{"199990000"});
  EXPECT_EQ(run("map(tostring) | add | length", json), Out{"88890"});
  EXPECT_EQ(run("[.[] | -.] | sort | .[0]", json), Out{"-19999"});
}

TEST(SpecExamples, Example1) {
  EXPECT_EQ(
      run(".users | map(select(.age >= 30 and .active)) | sort_by(.age) | reverse | map({name, age})",
          "{\"users\":[{\"name\":\"ann\",\"age\":31,\"active\":true},{\"name\":\"bob\",\"age\":45,"
          "\"active\":false},{\"name\":\"cy\",\"age\":30,\"active\":true},{\"name\":\"di\","
          "\"age\":52,\"active\":true},{\"name\":\"ed\",\"age\":29,\"active\":true},"
          "{\"name\":\"flo\",\"age\":31,\"active\":true}]}"),
      Out{"[{\"name\":\"di\",\"age\":52},{\"name\":\"flo\",\"age\":31},{\"name\":\"ann\",\"age\":31},"
          "{\"name\":\"cy\",\"age\":30}]"});
}

}  // namespace
