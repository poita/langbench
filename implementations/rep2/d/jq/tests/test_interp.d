module test_interp;

import helpers;
import jq;

unittest // paths
{
    assert(run(".a", `{"a":1}`) == "1");
    assert(run(".b", `{"a":1}`) == "null");
    assert(run(".a.b.c", `null`) == "null");
    assert(run(`."a b"`, `{"a b":2}`) == "2");
    assert(run(".[-1], .[5], .[0]", `[1,2,3]`) == "3\nnull\n1");
    assert(run(`.["a"]`, `{"a":1}`) == "1");
    assert(run(".[]", `{"b":1,"a":2}`) == "1\n2");
    assert(run(".[1:], .[:-1], .[1:2]", `[1,2,3]`) == "[2,3]\n[1,2]\n[2]");
    assert(run(".[1:3]", `"héllo"`) == `"él"`);
    assert(run(".[2:1]", `[1,2,3]`) == "[]");
    assert(run(".[1:]", `null`) == "null");
}

unittest // generator order
{
    assert(run("[(1,2) + (10,20)]", "null") == "[11,12,21,22]");
    assert(run("[([1,2],[3,4])[(0,1)]]", "null") == "[1,3,2,4]");
    assert(run("{a:(1,2), b:(3,4)}", "null") == "{\"a\":1,\"b\":3}\n{\"a\":1,\"b\":4}\n{\"a\":2,\"b\":3}\n{\"a\":2,\"b\":4}");
    assert(run("1, 2 | . * 10", "null") == "10\n20");
    assert(run("(1,2) as $x | (3,4) as $y | [$x,$y]", "null") == "[1,3]\n[1,4]\n[2,3]\n[2,4]");
}

unittest // optional
{
    assert(run(".a?", "5") == "");
    assert(run(".a.b?", "5") == "error");
    assert(run("[([1],2,[3])[0]?]", "null") == "[1,3]");
    assert(run("[(1,[2],3)[]?]", "null") == "[2]");
    assert(run("[(1,2,error,3)?]", "null") == "[1,2]");
    assert(run("(.a.b)?", "5") == "");
    assert(run("[.[] | tonumber?]", `["1","x","2.5",""]`) == "[1,2.5]");
    assert(run("(1,2)? | error", "null") == "error");
}

unittest // errors keep earlier outputs
{
    assert(run("1, 2, error, 3", "null") == "1\n2\nerror");
    assert(run("[1, error]", "null") == "error");
    assert(run(".[0]", `{"a":1}`) == "error");
    assert(run(".a", `[1]`) == "error");
    assert(run(".[null]", "null") == "error");
    assert(run("error(null)", "null") == "error");
    assert(run("error(empty)", "null") == "");
    assert(run("1 / 0", "null") == "error");
    assert(run("1 % 0", "null") == "error");
    assert(run(`"a" - 1`, "null") == "error");
}

unittest // arithmetic
{
    assert(run("1 + 2 * 3 - 4 / 2", "null") == "5");
    assert(run("-7 % 3, 7 % -3, 5.5 % 2", "null") == "-1\n1\n1");
    assert(run(`null + 1, 1 + null, null + null`, "null") == "1\n1\nnull");
    assert(run(`"a" + "b", [1] + [2], {a:1} + {b:2}`, "null") == "\"ab\"\n[1,2]\n{\"a\":1,\"b\":2}");
    assert(run(`{"z":1,"a":2} + {"m":3,"z":9}`, "null") == `{"z":9,"a":2,"m":3}`);
    assert(run(`{a:{b:1,c:2}} * {a:{b:3},d:1}`, "null") == `{"a":{"b":3,"c":2},"d":1}`);
    assert(run(`"ab" * 3, 0 * "x", "x" * -1`, "null") == "\"ababab\"\n\"\"\nnull");
    assert(run(`"a,b,,c" / ",", "" / ",", "abc" / ""`, "null") == `["a","b","","c"]` ~ "\n[]\n" ~ `["a","b","c"]`);
    assert(run("[1,2,3,2] - [2]", "null") == "[1,3]");
    assert(run("-(1 + 2), 2 * -3, 1 - -1", "null") == "-3\n-6\n2");
    assert(run("1 == (1.5 - 0.5)", "null") == "true");
}

unittest // comparison and logic
{
    assert(run(`[null,false,true,0,"a",[],{}] | sort == .`, "null") == "true");
    assert(run("1 < 2, 2 <= 2, 3 > 4, 1 != 1", "null") == "true\ntrue\nfalse\nfalse");
    assert(run("false and error", "null") == "false");
    assert(run("true or error", "null") == "true");
    assert(run("(true, false) and (true, false)", "null") == "true\nfalse\nfalse");
    assert(run("[null, 0, \"\", []] | map(not)", "null") == "[true,false,false,false]");
}

unittest // control flow and binding
{
    assert(run("if . then 1 elif 2 then 3 else 4 end", "false") == "3");
    assert(run("if . then 1 end", "null") == "null");
    assert(run("if (true,false) then 1 else 2 end", "null") == "1\n2");
    assert(run(". as $x | [$x, 1] | .[0] as $y | $y", "7") == "7");
    assert(run("1 as $x | 2 as $x | $x", "null") == "2");
    assert(run("reduce .[] as $x (0; . + $x)", "[1,2,3]") == "6");
    assert(run("reduce .[] as $x (0; empty)", "[1,2,3]") == "null");
    assert(run("reduce empty as $x (0; .+1)", "null") == "0");
    assert(run("reduce .[] as $o ({}; . + {($o.k): $o.v})", `[{"k":"b","v":1},{"k":"a","v":2}]`) == `{"b":1,"a":2}`);
}

unittest // builtins
{
    assert(run("length", `[1,2]`) == "2");
    assert(run("length", `"héllo"`) == "5");
    assert(run("length", `-3`) == "3");
    assert(run("length", `null`) == "0");
    assert(run("length", `true`) == "error");
    assert(run("keys", `{"b":1,"a":2}`) == `["a","b"]`);
    assert(run("keys", `[5,6]`) == `[0,1]`);
    assert(run("has(\"a\"), has(\"z\")", `{"a":1}`) == "true\nfalse");
    assert(run("has(1), has(2), has(-1), has(1.5)", `[1,2]`) == "true\nfalse\nfalse\ntrue");
    assert(run("has(0)", `null`) == "false");
    assert(run("has(0)", `{"a":1}`) == "error");
    assert(run("map(type)", `[null,true,1,"a",[],{}]`) == `["null","boolean","number","string","array","object"]`);
    assert(run("add", `[1,2,3]`) == "6");
    assert(run("add", `[]`) == "null");
    assert(run("add", `["a","b"]`) == `"ab"`);
    assert(run("add", `[[1],[2,3],null]`) == "[1,2,3]");
    assert(run("add", `[{"a":1},{"b":2},{"a":3}]`) == `{"a":3,"b":2}`);
    assert(run("add", `{"x":1,"y":2}`) == "3");
    assert(run("add", `[1,"a"]`) == "error");
    assert(run("map(select(. > 1))", `[1,2,3]`) == "[2,3]");
    assert(run("map(. * 2)", `{"a":1,"b":2}`) == "[2,4]");
    assert(run("map(.)", `1`) == "error");
    assert(run("sort", `[3,"a",null,1,[1],true]`) == `[null,true,1,3,"a",[1]]`);
    assert(run("sort", `1`) == "error");
    assert(run("unique", `[2,1,2,1]`) == "[1,2]");
    assert(run("reverse", `[1,2,3]`) == "[3,2,1]");
    assert(run("reverse", `null`) == "[]");
    assert(run("reverse", `"abc"`) == "error");
    assert(run("min, max", `[3,1,2]`) == "1\n3");
    assert(run("min, max", `[]`) == "null\nnull");
    assert(run("tostring", `[1,"a"]`) == `"[1,\"a\"]"`);
    assert(run("tostring", `"a"`) == `"a"`);
    assert(run("tonumber", `"12"`) == "12");
    assert(run("tonumber", `"-2.5"`) == "-2.5");
    assert(run("tonumber", `"abc"`) == "error");
    assert(run("tonumber", `""`) == "error");
    assert(run("tonumber", `true`) == "error");
    assert(run("[.[] | empty]", `[1]`) == "[]");
}

unittest // sorting builtins are stable and use [f] keys
{
    auto doc = `[{"k":"b","v":1},{"k":"a","v":2},{"k":"b","v":3}]`;
    assert(run("sort_by(.k) | map(.v)", doc) == "[2,1,3]");
    assert(run("sort_by(.k, -.v) | map(.v)", doc) == "[2,3,1]");
    assert(run("group_by(.k) | map(map(.v))", doc) == "[[2],[1,3]]");
    assert(run("sort_by(-.v) | map(.v)", `[{"v":0},{"v":1}]`) == "[1,0]");
    assert(run("sort_by(.a)", `{"a":1}`) == "error");
}

unittest // min/max tie rules
{
    auto doc = `[{"a":1,"b":2},{"b":2,"a":1}]`;
    assert(run("min", doc) == `{"a":1,"b":2}`);
    assert(run("max", doc) == `{"b":2,"a":1}`);
}

unittest // object construction
{
    assert(run("{a:1,b:2,a:3}", "null") == `{"a":3,"b":2}`);
    assert(run("{a,b}", `{"a":1,"b":2,"c":3}`) == `{"a":1,"b":2}`);
    assert(run(`{"a b"}`, `{"a b":1}`) == `{"a b":1}`);
    assert(run("1 as $v | {$v}", "null") == `{"v":1}`);
    assert(run(`{(.k): .v}`, `{"k":"x","v":1}`) == `{"x":1}`);
    assert(run(`{(1): 2}`, "null") == "error");
    assert(run("{a: .x | length}", `{"x":[1,2]}`) == `{"a":2}`);
    assert(run("{a: -1}", "null") == `{"a":-1}`);
    assert(run("{}", "null") == "{}");
}

unittest // try scope: only errors inside the term are caught
{
    assert(run("[.[] | (if . == 2 then error else . end)?]", "[1,2,3]") == "[1,3]");
    assert(run("(1,2,3) | (. | tostring)? | error", "null") == "error");
}

unittest // values are shared, not mutated
{
    assert(run(". as $o | [$o + {b:2}, $o, $o * {a:5}, $o]", `{"a":1}`) == `[{"a":1,"b":2},{"a":1},{"a":5},{"a":1}]`);
    assert(run(". as $a | [$a + [2], $a, $a - [1], $a]", `[1]`) == "[[1,2],[1],[],[1]]");
}

unittest // Program API
{
    auto p = new Program(".[] | . * 2");
    auto outs = p.runAll(parseJson("[1,2,3]"));
    assert(outs.length == 3 && outs[2].num == 6);
    // emit can stop early
    int seen;
    JqError err;
    assert(p.run(parseJson("[1,2,3]"), (Value v) { ++seen; return false; }, err));
    assert(seen == 1);
    import std.exception : assertThrown;
    assertThrown!JqException(new Program("error").runAll(Value.nullValue));
}
