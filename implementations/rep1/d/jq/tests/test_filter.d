module tests.test_filter;

import std.exception : assertThrown;
import jq;
import tests.helpers;

unittest // paths
{
    assert(runFilter(`.`, `{"a":1}`) == [`{"a":1}`]);
    assert(runFilter(`.a.b`, `{"a":{"b":2}}`) == [`2`]);
    assert(runFilter(`.a.b.c`, `{}`) == [`null`]);
    assert(runFilter(`."a b"`, `{"a b":1}`) == [`1`]);
    assert(runFilter(`.[1], .[-1], .[9]`, `[1,2,3]`) == [`2`, `3`, `null`]);
    assert(runFilter(`.["a"]`, `{"a":5}`) == [`5`]);
    assert(runFilter(`.[]`, `{"b":1,"a":2}`) == [`1`, `2`]);
    assert(runFilter(`.[1:]`, `[1,2,3]`) == [`[2,3]`]);
    assert(runFilter(`.[:2]`, `"héllo"`) == [`"hé"`]);
    assert(runFilter(`([1,2],[3,4])[(0,1)]`, `null`) == [`1`, `3`, `2`, `4`]);
}

unittest // generators and ordering
{
    assert(runFilter(`[(1,2) + (10,20)]`, `null`) == [`[11,12,21,22]`]);
    assert(runFilter(`{a:(1,2), b:(3,4)}`, `null`)
        == [`{"a":1,"b":3}`, `{"a":1,"b":4}`, `{"a":2,"b":3}`, `{"a":2,"b":4}`]);
    assert(runFilter(`1, 2 | . * 10`, `null`) == [`10`, `20`]);
    assert(runFilter(`{a:1,b:2,a:3}`, `null`) == [`{"a":3,"b":2}`]);
    assert(runFilter(`{(("x","y")): 1}`, `null`) == [`{"x":1}`, `{"y":1}`]);
    assert(runFilter(`[empty]`, `null`) == [`[]`]);
}

unittest // optional and try
{
    assert(runFilter(`.a?`, `5`) == []);
    assert(runFilter(`.a.b?`, `5`) == [`error`]);
    assert(runFilter(`[([1],2,[3])[0]?]`, `null`) == [`[1,3]`]);
    assert(runFilter(`[(1,[2],3)[]?]`, `null`) == [`[2]`]);
    assert(runFilter(`[(1,2,error,3)?]`, `null`) == [`[1,2]`]);
    assert(runFilter(`(.a.b)?`, `5`) == []);
    assert(runFilter(`(1,2)? | error`, `null`) == [`error`]);
    assert(runFilter(`[.[] | tonumber?]`, `["1","x","2"]`) == [`[1,2]`]);
    assert(runFilter(`[.[] | .a?]`, `[{"a":1},5]`) == [`[1]`]);
}

unittest // errors stop evaluation after earlier output
{
    assert(runFilter(`1, error, 2`, `null`) == [`1`, `error`]);
    assert(runFilter(`.[] | if . == 2 then error else . end`, `[1,2,3]`) == [`1`, `error`]);
    assert(runFilter(`[.[] | error]`, `[1]`) == [`error`]);
    assert(runFilter(`error(null)`, `1`) == [`error`]);
    assert(runFilter(`error(empty)`, `1`) == []);
    assert(runFilter(`{(.k): 1}`, `{"k":1}`) == [`error`]);
    assert(runFilter(`.[] | length`, `[true]`) == [`error`]);
}

unittest // boolean logic and conditionals
{
    assert(runFilter(`false and error`, `null`) == [`false`]);
    assert(runFilter(`true or error`, `null`) == [`true`]);
    assert(runFilter(`(true,false) and (true,false)`, `null`) == [`true`, `false`, `false`]);
    assert(runFilter(`if . then 1 elif . == null then 2 else 3 end`, `null`) == [`2`]);
    assert(runFilter(`if . > 1 then "big" end`, `0`) == [`0`]);
    assert(runFilter(`[.[] | not]`, `[null,0,false]`) == [`[true,false,true]`]);
}

unittest // variables and reduce
{
    assert(runFilter(`. as $x | [$x, $x + 1]`, `1`) == [`[1,2]`]);
    assert(runFilter(`1 as $x | 2 as $x | $x`, `null`) == [`2`]);
    assert(runFilter(`(1,2) as $x | $x * 10`, `null`) == [`10`, `20`]);
    assert(runFilter(`reduce .[] as $x (0; . + $x)`, `[1,2,3]`) == [`6`]);
    assert(runFilter(`reduce .[] as $o ({}; . + {($o.k): $o.v})`, `[{"k":"b","v":1},{"k":"a","v":2}]`)
        == [`{"b":1,"a":2}`]);
    assert(runFilter(`reduce empty as $x (0; .+1)`, `null`) == [`0`]);
    assert(runFilter(`reduce (1,2) as $x (0; empty)`, `null`) == [`null`]);
}

unittest // builtins
{
    assert(runFilter(`map(select(. > 1))`, `[1,2,3]`) == [`[2,3]`]);
    assert(runFilter(`map(. * 2)`, `{"a":1,"b":2}`) == [`[2,4]`]);
    assert(runFilter(`sort_by(.a, .b)`, `[{"a":1,"b":2},{"a":0,"b":9},{"a":1,"b":1}]`)
        == [`[{"a":0,"b":9},{"a":1,"b":1},{"a":1,"b":2}]`]);
    assert(runFilter(`group_by(.k) | map(length)`, `[{"k":2},{"k":1},{"k":2}]`) == [`[1,2]`]);
    assert(runFilter(`group_by(.k)`, `[]`) == [`[]`]);
    assert(runFilter(`unique`, `[3,1,3]`) == [`[1,3]`]);
    assert(runFilter(`keys, length, type`, `{"b":1,"a":2}`) == [`["a","b"]`, `2`, `"object"`]);
    assert(runFilter(`has("a")`, `{"a":null}`) == [`true`]);
    assert(runFilter(`map({name, age})`, `[{"name":"x","age":1,"z":0}]`) == [`[{"name":"x","age":1}]`]);
    assert(runFilter(`1 as $x | {$x, "y"}`, `{"y":7}`) == [`{"x":1,"y":7}`]);
    assert(runFilter(`-.a, -(.a + 1), 2 * -3, 1 - -1`, `{"a":3}`) == [`-3`, `-4`, `-6`, `2`]);
    assert(runFilter(`[.[] | tostring]`, `[1,"a",[1],null]`) == [`["1","a","[1]","null"]`]);
}

unittest // filter syntax errors are reported by compile
{
    assertThrown!FilterException(Program.compile(`.a |`));
    assertThrown!FilterException(Program.compile(`nosuchbuiltin`));
    assertThrown!FilterException(Program.compile(`$undefined`));
    assertThrown!FilterException(Program.compile(`[1, 2`));
}

unittest // a compiled program is reusable
{
    auto p = Program.compile(`.n * 2`);
    RunStatus st;
    foreach (i; 0 .. 3)
    {
        auto outs = p.runAll(parseJson(`{"n":` ~ toJson(Value.makeNumber(i)) ~ `}`), st);
        assert(st.ok && toJson(outs[0]) == toJson(Value.makeNumber(i * 2)));
    }
}
