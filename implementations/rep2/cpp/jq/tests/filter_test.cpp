#include <gtest/gtest.h>

#include <string>

#include "jq/jq.hpp"

namespace {

// Runs `program` on `doc`, returning the compact outputs joined by newlines
// (with a trailing "error" line when evaluation fails).
std::string run(const std::string& program, const std::string& doc = "null") {
  std::string text = jq::run_to_text(program, doc);
  if (!text.empty() && text.back() == '\n') text.pop_back();
  return text;
}

}  // namespace

TEST(Paths, FieldIndexSliceIterate) {
  EXPECT_EQ(run(".a.b", R"({"a":{"b":7}})"), "7");
  EXPECT_EQ(run(".missing.x", "{}"), "null");
  EXPECT_EQ(run(".[-1], .[5]", "[1,2,3]"), "3\nnull");
  EXPECT_EQ(run(".[1:3], .[:1], .[-2:]", "[1,2,3,4]"), "[2,3]\n[1]\n[3,4]");
  EXPECT_EQ(run(".[1:3]", "\"aéèz\""), "\"éè\"");
  EXPECT_EQ(run(".[]", R"({"b":1,"a":2})"), "1\n2");
  EXPECT_EQ(run(".[2:1]", "[1,2,3]"), "[]");
}

TEST(Paths, GeneratorOrder) {
  EXPECT_EQ(run("[([1,2],[3,4])[(0,1)]]"), "[1,3,2,4]");
  EXPECT_EQ(run("[(1,2) + (10,20)]"), "[11,12,21,22]");
  EXPECT_EQ(run("{a:(1,2), b:(3,4)}"), "{\"a\":1,\"b\":3}\n{\"a\":1,\"b\":4}\n{\"a\":2,\"b\":3}\n{\"a\":2,\"b\":4}");
}

TEST(Paths, ErrorsAndOptional) {
  EXPECT_EQ(run(".a", "5"), "error");
  EXPECT_EQ(run(".a?", "5"), "");
  EXPECT_EQ(run(".a.b?", "5"), "error");
  EXPECT_EQ(run("[([1],2,[3])[0]?]"), "[1,3]");
  EXPECT_EQ(run("[(1,[2],3)[]?]"), "[2]");
  EXPECT_EQ(run("[(1,2,error,3)?]"), "[1,2]");
  EXPECT_EQ(run("(1,2)? | error"), "error");
  EXPECT_EQ(run(".[null]", "null"), "error");
  EXPECT_EQ(run("[.[] | tonumber?]", R"(["1","x","2.5"])"), "[1,2.5]");
  EXPECT_EQ(run("1, error(null), 2"), "1\nerror");
}

TEST(Arithmetic, Basics) {
  EXPECT_EQ(run("1 + 2 * 3 - 4 / 2 % 3"), "5");
  EXPECT_EQ(run("[-7 % 3, 7 % -3, 5.5 % 2, 2 * -3, 1 - -1]"), "[-1,1,1,-6,2]");
  EXPECT_EQ(run("5 % 0.5"), "error");
  EXPECT_EQ(run("1 / 0"), "error");
  EXPECT_EQ(run("[0.001 * 1000, 10 / 4]"), "[1,2.5]");
}

TEST(Arithmetic, NonNumbers) {
  EXPECT_EQ(run("[(null + 1), (1 + null), (\"a\" + \"b\"), ([1] + [2]), ({} + null)]"), "[1,1,\"ab\",[1,2],{}]");
  EXPECT_EQ(run("[1,2,3,2] - [2]"), "[1,3]");
  EXPECT_EQ(run("[(\"ab\" * 3), (3 * \"ab\"), (\"ab\" * 0), (\"ab\" * -1)]"), "[\"ababab\",\"ababab\",\"\",null]");
  EXPECT_EQ(run("[\"a,b,,c\" / \",\", \"\" / \",\", \"abc\" / \"\"]"), "[[\"a\",\"b\",\"\",\"c\"],[],[\"a\",\"b\",\"c\"]]");
  EXPECT_EQ(run("1 + \"a\""), "error");
  EXPECT_EQ(run("null - 1"), "error");
}

TEST(Arithmetic, ObjectMergeKeepsOrder) {
  EXPECT_EQ(run("{\"z\":1,\"a\":2} + {\"m\":3,\"z\":9}"), "{\"z\":9,\"a\":2,\"m\":3}");
  EXPECT_EQ(run("{\"a\":{\"x\":1,\"y\":2},\"q\":0} * {\"a\":{\"z\":3,\"x\":9},\"b\":1}"),
            "{\"a\":{\"x\":9,\"y\":2,\"z\":3},\"q\":0,\"b\":1}");
  EXPECT_EQ(run("{b:1,a:2,b:3}"), "{\"b\":3,\"a\":2}");
}

TEST(Comparison, TotalOrder) {
  EXPECT_EQ(run("[null < false, false < true, true < 0, -1 < \"\", \"Z\" < \"a\", [] < {}, 1 == (1.5 - 0.5)]"),
            "[true,true,true,true,true,true,true]");
  EXPECT_EQ(run("[{\"a\":1,\"b\":2} == {\"b\":2,\"a\":1}, [1] < [1,0]]"), "[true,true]");
}

TEST(Logic, ShortCircuitAndStreams) {
  EXPECT_EQ(run("[false and error, true or error]"), "[false,true]");
  EXPECT_EQ(run("[(true,false) and (true,false)]"), "[true,false,false]");
  EXPECT_EQ(run("[(false,true) or (false,true)]"), "[false,true,true]");
  EXPECT_EQ(run("[if (true,false) then 1 end]"), "[1,null]");
  EXPECT_EQ(run("[.[] | if . > 1 then \"big\" elif . > 0 then \"small\" else \"neg\" end]", "[2,1,-1]"),
            "[\"big\",\"small\",\"neg\"]");
}

TEST(Binding, VariablesAndReduce) {
  EXPECT_EQ(run(". as $x | 1 as $y | [$x, $y, (2 as $y | $y), $y]", "9"), "[9,1,2,1]");
  EXPECT_EQ(run("[.[] as $x | .[] as $y | select($x < $y) | [$x, $y]]", "[1,2,3]"), "[[1,2],[1,3],[2,3]]");
  EXPECT_EQ(run("reduce .[] as $x (0; . + $x)", "[1,2,3]"), "6");
  EXPECT_EQ(run("reduce (1,2,3) as $x (0; if $x == 2 then empty else . + $x end)"), "3");
  EXPECT_EQ(run("reduce (1,2) as $x ((0,10); . + $x)"), "3\n13");
  EXPECT_EQ(run("reduce .[] as $o ({}; . + {($o.k): $o.v})", R"([{"k":"b","v":1},{"k":"a","v":2}])"),
            R"({"b":1,"a":2})");
}

TEST(Builtins, Collections) {
  EXPECT_EQ(run("keys", R"({"b":1,"a":2})"), "[\"a\",\"b\"]");
  EXPECT_EQ(run("keys", "[5,6]"), "[0,1]");
  EXPECT_EQ(run("[has(\"a\"), has(\"z\")]", R"({"a":1})"), "[true,false]");
  EXPECT_EQ(run("[has(0), has(2), has(-1), has(1.5)]", "[1,2]"), "[true,false,false,true]");
  EXPECT_EQ(run("[length]", "\"éé\""), "[2]");
  EXPECT_EQ(run("[(null|length), (-2.5|length), ([1]|length)]"), "[0,2.5,1]");
  EXPECT_EQ(run("true | length"), "error");
  EXPECT_EQ(run("[.[] | type]", R"([null,true,1,"a",[],{}])"),
            "[\"null\",\"boolean\",\"number\",\"string\",\"array\",\"object\"]");
  EXPECT_EQ(run("add", "[[1],null,[2]]"), "[1,2]");
  EXPECT_EQ(run("add", "[]"), "null");
  EXPECT_EQ(run("add", R"({"a":"x","b":"y"})"), "\"xy\"");
  EXPECT_EQ(run("add", R"([1,"a"])"), "error");
  EXPECT_EQ(run("map(. + 1)", "[1,2]"), "[2,3]");
  EXPECT_EQ(run("map(. + 1)", R"({"a":1})"), "[2]");
  EXPECT_EQ(run("map(.)", "null"), "error");
  EXPECT_EQ(run("reverse", "null"), "[]");
  EXPECT_EQ(run("reverse", "\"abc\""), "error");
}

TEST(Builtins, SortingAndGrouping) {
  EXPECT_EQ(run("sort", R"([3,"a",null,[1],{"a":1},true,false,1])"), R"([null,false,true,1,3,"a",[1],{"a":1}])");
  const char* doc = R"([{"a":2,"b":1,"i":0},{"a":1,"b":2,"i":1},{"a":2,"b":0,"i":2},{"a":1,"b":2,"i":3}])";
  EXPECT_EQ(run("[sort_by(.a) | .[] | .i]", doc), "[1,3,0,2]");
  EXPECT_EQ(run("[sort_by(.a, .b) | .[] | .i]", doc), "[1,3,2,0]");
  EXPECT_EQ(run("[sort_by(-.b) | .[] | .i]", doc), "[1,3,0,2]");
  EXPECT_EQ(run("group_by(.a) | map(map(.i))", doc), "[[1,3],[0,2]]");
  EXPECT_EQ(run("unique", "[3,1,2,1,3]"), "[1,2,3]");
  EXPECT_EQ(run("[min, max]", "[3,1,2]"), "[1,3]");
  EXPECT_EQ(run("[([] | min), ([] | max)]"), "[null,null]");
  EXPECT_EQ(run("sort", "{}"), "error");
}

TEST(Builtins, Conversions) {
  EXPECT_EQ(run("[.[] | tostring]", R"(["a",1,[1,"b"],null,{"k":1.5}])"), R"(["a","1","[1,\"b\"]","null","{\"k\":1.5}"])");
  EXPECT_EQ(run("[.[] | tonumber]", R"(["12","-2.5","0",3])"), "[12,-2.5,0,3]");
  EXPECT_EQ(run("tonumber", "\"abc\""), "error");
  EXPECT_EQ(run("tonumber", "\"\""), "error");
  EXPECT_EQ(run("tonumber", "[1]"), "error");
}

TEST(Builtins, ErrorAndEmpty) {
  EXPECT_EQ(run("[empty, 1, empty, 2]"), "[1,2]");
  EXPECT_EQ(run("[error(empty)]"), "[]");
  EXPECT_EQ(run("1, 2 | . * 10"), "10\n20");
  EXPECT_EQ(run("[.[] | if . == 2 then error(\"boom\") else . end]", "[1,2]"), "error");
}

TEST(Objects, Construction) {
  EXPECT_EQ(run("{$x}"), "error");  // unbound variable
  EXPECT_EQ(run(". as $x | {a, \"b\", $x, (.c + \"_k\"): .d, g: -1}", R"({"a":1,"b":2,"c":"c","d":4})"),
            R"({"a":1,"b":2,"x":{"a":1,"b":2,"c":"c","d":4},"c_k":4,"g":-1})");
  EXPECT_EQ(run("{(.k): 1}", R"({"k":5})"), "error");
}

TEST(Api, StreamingAndPartialResults) {
  jq::Filter f = jq::Filter::compile("1, 2, error, 3");
  std::vector<double> seen;
  jq::RunStatus st = f.run(jq::Value(), [&](const jq::Value& v) {
    seen.push_back(v.as_number());
    return true;
  });
  EXPECT_FALSE(st.ok);
  EXPECT_EQ(seen, (std::vector<double>{1, 2}));
  EXPECT_THROW(f.run_all(jq::Value()), jq::EvalError);
}

TEST(Api, SinkCanStopEarly) {
  jq::Filter f = jq::Filter::compile("(1,2,3), error");
  int count = 0;
  jq::RunStatus st = f.run(jq::Value(), [&](const jq::Value&) { return ++count < 2; });
  EXPECT_TRUE(st.ok);
  EXPECT_EQ(count, 2);
}

TEST(Api, StopThroughTryIsNotSwallowed) {
  jq::Filter f = jq::Filter::compile("(1,2,3)?");
  int count = 0;
  jq::RunStatus st = f.run(jq::Value(), [&](const jq::Value&) { return ++count < 2; });
  EXPECT_TRUE(st.ok);
  EXPECT_EQ(count, 2);
}

TEST(Api, SharedValuesAreImmutable) {
  jq::Value doc = jq::parse_json(R"({"a":[1,2]})");
  jq::Filter::compile(". + {b: 1} | .a + [3]").run_all(doc);
  EXPECT_EQ(jq::to_json(doc), R"({"a":[1,2]})");
}

TEST(Api, DeepChainsAndLargeInputs) {
  std::string doc = "[";
  for (int i = 0; i < 20000; ++i) doc += (i ? "," : "") + std::string("{\"id\":") + std::to_string(i) + "}";
  doc += "]";
  EXPECT_EQ(run("map(.id) | add", doc), "199990000");
  EXPECT_EQ(run("[.[] | select(.id % 1000 == 0)] | length", doc), "20");
}
