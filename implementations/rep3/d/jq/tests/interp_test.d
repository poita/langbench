module tests.interp_test;

import std.array : join;
import jq;

/// Outputs joined by newline; "error" appended when evaluation fails.
private string q(string filter, string json)
{
    auto r = query(filter, json);
    auto lines = r.outputs.dup;
    if (r.failed)
        lines ~= "error";
    return lines.join("\n");
}

unittest // paths
{
    assert(q(".", `{"a":1}`) == `{"a":1}`);
    assert(q(".a.b", `{"a":{"b":2}}`) == "2");
    assert(q(`."a b"`, `{"a b":3}`) == "3");
    assert(q(".x.y.z", `{}`) == "null");
    assert(q(".[1], .[-1], .[5]", `[1,2,3]`) == "2\n3\nnull");
    assert(q(".[]", `{"b":1,"a":2}`) == "1\n2");
    assert(q(".[1:], .[:-1], .[5:]", `[1,2,3]`) == "[2,3]\n[1,2]\n[]");
    assert(q(`.[1:3]`, `"aéxyz"`) == `"éx"`);
    assert(q(`([1,2],[3,4])[(0,1)]`, `null`) == "1\n3\n2\n4");
}

unittest // optional and try
{
    assert(q(".a?", `5`) == "");
    assert(q(".a.b?", `5`) == "error");
    assert(q("[([1],2,[3])[0]?]", `null`) == "[1,3]");
    assert(q("[(1,[2],3)[]?]", `null`) == "[2]");
    assert(q("[(1,2,error,3)?]", `null`) == "[1,2]");
    assert(q("(1,2)? | error", `null`) == "error");
    assert(q("[.[] | tonumber?]", `["1","x","2.5"]`) == "[1,2.5]");
    assert(q("[.a??]", `5`) == "[]");
    // an error raised downstream of try is not swallowed by it
    assert(q("[(1,2)? | if . == 2 then error else . end]", `null`) == "error");
}

unittest // generator order
{
    assert(q("[(1,2) + (10,20)]", `null`) == "[11,12,21,22]");
    assert(q("{a:(1,2), b:(3,4)}", `null`) ==
            `{"a":1,"b":3}` ~ "\n" ~ `{"a":1,"b":4}` ~ "\n" ~ `{"a":2,"b":3}` ~ "\n" ~ `{"a":2,"b":4}`);
    assert(q("1, 2 | . * 10", `null`) == "10\n20");
    assert(q("false and error, (true and (true, false))", `null`) == "false\ntrue\nfalse");
}

unittest // arithmetic
{
    assert(q("1 - -1, -(2 + 3), 7 / 2, -7 % 3, 7 % -3, 5.5 % 2", `null`) == "2\n-5\n3.5\n-1\n1\n1");
    assert(q("null + 1, 1 + null, \"a\" + \"b\", [1] + [2]", `null`) == "1\n1\n\"ab\"\n[1,2]");
    assert(q(`{"z":1,"a":2} + {"m":3,"z":9}`, `null`) == `{"z":9,"a":2,"m":3}`);
    assert(q(`{"a":{"b":1,"c":2}} * {"a":{"b":9},"d":1}`, `null`) == `{"a":{"b":9,"c":2},"d":1}`);
    assert(q(`[1,2,3,2] - [2]`, `null`) == "[1,3]");
    assert(q(`"ab" * 3, "ab" * 0, "ab" * -1`, `null`) == "\"ababab\"\n\"\"\nnull");
    assert(q(`"a,b,,c" / ",", "" / ",", "abc" / ""`, `null`) == `["a","b","","c"]` ~ "\n[]\n" ~ `["a","b","c"]`);
    assert(q("1 / 0", `null`) == "error");
    assert(q("5 % 0.5", `null`) == "error");
    assert(q(`"a" - 1`, `null`) == "error");
}

unittest // variables, reduce, if
{
    assert(q(". as $x | [$x, $x + 1]", `1`) == "[1,2]");
    assert(q("(1,2) as $x | (10,20) as $y | $x + $y", `null`) == "11\n21\n12\n22");
    assert(q("1 as $x | 2 as $x | $x", `null`) == "2");
    assert(q("reduce .[] as $v (0; . + $v)", `[1,2,3]`) == "6");
    assert(q("reduce .[] as $v (0; empty)", `[1,2]`) == "null");
    assert(q(`if . > 1 then "big" elif . == 1 then "one" else "small" end`, `1`) == `"one"`);
    assert(q(`if . then 1 end`, `false`) == "false");
}

unittest // object construction
{
    assert(q("{a:1,b:2,a:3}", `null`) == `{"a":3,"b":2}`);
    assert(q("{a, b}", `{"a":1,"b":2,"c":3}`) == `{"a":1,"b":2}`);
    assert(q(`{"x y"}`, `{"x y":1}`) == `{"x y":1}`);
    assert(q(`1 as $v | {$v, (.k): 2, "s": -1 | -.}`, `{"k":"kk"}`) == `{"v":1,"kk":2,"s":1}`);
    assert(q(`{(1): 2}`, `null`) == "error");
}

unittest // builtins
{
    assert(q("length", `"héé"`) == "3");
    assert(q("length", `-4`) == "4");
    assert(q("length", `null`) == "0");
    assert(q("length", `true`) == "error");
    assert(q("keys", `{"b":1,"a":2}`) == `["a","b"]`);
    assert(q("keys", `[7,8]`) == `[0,1]`);
    assert(q("has(\"a\"), has(\"z\")", `{"a":1}`) == "true\nfalse");
    assert(q("has(1), has(2), has(1.5), has(-1)", `[1,2]`) == "true\nfalse\ntrue\nfalse");
    assert(q("type", `[]`) == `"array"`);
    assert(q("add", `[1,2,3]`) == "6");
    assert(q("add", `["a","b"]`) == `"ab"`);
    assert(q("add", `[[1],[2],null]`) == "[1,2]");
    assert(q("add", `[{"a":1},{"b":2},{"a":3}]`) == `{"a":3,"b":2}`);
    assert(q("add", `[]`) == "null");
    assert(q("add", `[1,"a"]`) == "error");
    assert(q("map(. + 1)", `[1,2]`) == "[2,3]");
    assert(q("map(.)", `{"a":1,"b":2}`) == "[1,2]");
    assert(q("map(select(. > 1))", `[1,2,3]`) == "[2,3]");
    assert(q("sort", `[3,"a",null,[1],{"a":1},true,false,1]`) ==
            `[null,false,true,1,3,"a",[1],{"a":1}]`);
    assert(q("sort_by(.a, .b)", `[{"a":2,"b":1},{"a":1,"b":2},{"a":1,"b":1}]`) ==
            `[{"a":1,"b":1},{"a":1,"b":2},{"a":2,"b":1}]`);
    assert(q("sort_by(.k)", `[{"k":1,"i":0},{"k":0,"i":1},{"k":1,"i":2},{"k":0,"i":3}]`) ==
            `[{"k":0,"i":1},{"k":0,"i":3},{"k":1,"i":0},{"k":1,"i":2}]`);
    assert(q("group_by(.k)", `[{"k":2},{"k":1},{"k":2}]`) == `[[{"k":1}],[{"k":2},{"k":2}]]`);
    assert(q("unique", `[3,1,3,2,1]`) == "[1,2,3]");
    assert(q("reverse", `[1,2,3]`) == "[3,2,1]");
    assert(q("reverse", `null`) == "[]");
    assert(q("reverse", `"ab"`) == "error");
    assert(q("min, max", `[2,1,3]`) == "1\n3");
    assert(q("min, max", `[]`) == "null\nnull");
    assert(q("min, max", `[{"a":1,"b":2},{"b":2,"a":1}]`) == `{"a":1,"b":2}` ~ "\n" ~ `{"b":2,"a":1}`);
    assert(q("tostring", `[1,"a"]`) == `"[1,\"a\"]"`);
    assert(q("tonumber", `"-2.5"`) == "-2.5");
    assert(q("tonumber", `""`) == "error");
    assert(q("not", `null`) == "true");
    assert(q("[empty]", `null`) == "[]");
    assert(q("error(null)", `null`) == "error");
    assert(q("[error(empty)]", `null`) == "[]");
}

unittest // partial output before an error
{
    assert(q(".[] | if . == 2 then error else . end", `[1,2,3]`) == "1\nerror");
}

unittest // filters are parsed with the documented precedence
{
    assert(q("1, 2 | . + 1", `null`) == "2\n3");
    assert(q("[1 -1]", `null`) == "[0]");
    assert(q("1 + 2 * 3 == 7 and true or false", `null`) == "true");
    bool threw;
    try
        compile("1 +");
    catch (ParseError)
        threw = true;
    assert(threw);
}
