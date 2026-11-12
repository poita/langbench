/// End-to-end tests of the filter language through the public API.
module tests.spec_examples;

import std.array : join;
import core.exception : AssertError;
import std.exception : assertThrown;

import jq;

/// Runs `filter` on `doc`; returns the output lines, with a final "error" if
/// evaluation failed (the same contract as the command-line tool).
private string[] run(string filter, string doc)
{
    string[] lines;
    try
        Filter.compile(filter).run(parseJson(doc), (Value v) { lines ~= toJson(v); });
    catch (JqError)
        lines ~= "error";
    return lines;
}

private void check(string filter, string doc, string[] expected, string file = __FILE__, size_t line = __LINE__)
{
    auto got = run(filter, doc);
    if (got != expected)
        throw new AssertError("filter `" ~ filter ~ "`: got " ~ got.join(" | ") ~ ", expected "
                ~ expected.join(" | "), file, line);
}

unittest // paths
{
    check(`.`, `{"b":1,"a":[1,2]}`, [`{"b":1,"a":[1,2]}`]);
    check(`.a.b, .a["b"], ."a"."b"`, `{"a":{"b":7}}`, [`7`, `7`, `7`]);
    check(`.[-1], .[5], .[0]`, `[1,2,3]`, [`3`, `null`, `1`]);
    check(`.[1:], .[:-1], .[-2:5]`, `[1,2,3]`, [`[2,3]`, `[1,2]`, `[2,3]`]);
    check(`.[1:3]`, `"aé😀bc"`, [`"é😀"`]);
    check(`.[]`, `{"z":1,"a":2}`, [`1`, `2`]);
    check(`.a`, `null`, [`null`]);
    check(`.a`, `5`, [`error`]);
    check(`.[]`, `null`, [`error`]);
    check(`.[null]`, `null`, [`error`]);
}

unittest // generators and ordering
{
    check(`[(1,2) + (10,20)]`, `null`, [`[11,12,21,22]`]);
    check(`{a:(1,2), b:(3,4)}`, `null`, [`{"a":1,"b":3}`, `{"a":1,"b":4}`, `{"a":2,"b":3}`, `{"a":2,"b":4}`]);
    check(`[([1,2],[3,4])[(0,1)]]`, `null`, [`[1,3,2,4]`]);
    check(`[.[] as $x | .[] as $y | [$x,$y]]`, `[1,2]`, [`[[1,1],[1,2],[2,1],[2,2]]`]);
    check(`1, 2 | . * 10`, `null`, [`10`, `20`]);
    check(`false and error, true or error`, `null`, [`false`, `true`]);
}

unittest // optional and try
{
    check(`.a?`, `5`, []);
    check(`.a.b?`, `5`, [`error`]);
    check(`[([1],2,[3])[0]?]`, `null`, [`[1,3]`]);
    check(`[(1,[2],3)[]?]`, `null`, [`[2]`]);
    check(`[(1,2,error,3)?]`, `null`, [`[1,2]`]);
    check(`(1,2)? | error`, `null`, [`error`]);
    check(`[.[] | tonumber?]`, `["1","x","2.5"]`, [`[1,2.5]`]);
    check(`[((1,2)? | error)?]`, `null`, [`[]`]);
}

unittest // errors keep earlier output
{
    check(`1, 2, error, 3`, `null`, [`1`, `2`, `error`]);
    check(`.[] | .a.b?`, `[{"a":{"b":1}},{"a":5},3]`, [`1`, `error`]);
    check(`error(null)`, `null`, [`error`]);
    check(`[error(empty)]`, `null`, [`[]`]);
}

unittest // arithmetic
{
    check(`null + 1, 1 + null, "a" + "b", [1] + [2]`, `null`, [`1`, `1`, `"ab"`, `[1,2]`]);
    check(`{"z":1,"a":2} + {"m":3,"z":9}`, `null`, [`{"z":9,"a":2,"m":3}`]);
    check(`{"a":{"b":1,"c":2}} * {"a":{"b":3}}`, `null`, [`{"a":{"b":3,"c":2}}`]);
    check(`[1,2,3,2] - [2]`, `null`, [`[1,3]`]);
    check(`"ab" * 2, "ab" * 0, "ab" * -1`, `null`, [`"abab"`, `""`, `null`]);
    check(`"a,b,,c" / ",", "" / ",", "abc" / ""`, `null`, [`["a","b","","c"]`, `[]`, `["a","b","c"]`]);
    check(`-7 % 3, 7 % -3, 5.5 % 2`, `null`, [`-1`, `1`, `1`]);
    check(`1 / 0`, `null`, [`error`]);
    check(`5 % 0.5`, `null`, [`error`]);
    check(`1 == (1.5 - 0.5), {a:1,b:2} == {b:2,a:1}, "Z" < "a", [] < {}`, `null`, [`true`, `true`, `true`, `true`]);
    check(`-.a, -(.a + 1), 2 * -3, 1 - -1`, `{"a":2}`, [`-2`, `-3`, `-6`, `2`]);
}

unittest // constructors, control flow
{
    check(`{a:1,b:2,a:3}`, `null`, [`{"a":3,"b":2}`]);
    check(`3 as $x | {a, "b", $x}`, `{"a":1,"b":2}`, [`{"a":1,"b":2,"x":3}`]);
    check(`{(.k): .v, "lit": 1}`, `{"k":"n","v":2}`, [`{"n":2,"lit":1}`]);
    check(`{(1): 2}`, `null`, [`error`]);
    check(`[.[] | if . > 1 then "big" elif . == 1 then "one" else "small" end]`, `[0,1,2]`,
            [`["small","one","big"]`]);
    check(`if . then 1 end`, `false`, [`false`]);
    check(`reduce .[] as $x (0; . + $x)`, `[1,2,3]`, [`6`]);
    check(`reduce .[] as $x (0; empty)`, `[1,2,3]`, [`null`]);
    check(`[.[] as $x | $x | . as $x | $x + 1]`, `[1,2]`, [`[2,3]`]);
}

unittest // builtins
{
    check(`length`, `"aé😀"`, [`3`]);
    check(`map(length)`, `[null,-3,"ab",[1],{"a":1}]`, [`[0,3,2,1,1]`]);
    check(`true | length`, `null`, [`error`]);
    check(`keys`, `{"b":1,"a":2}`, [`["a","b"]`]);
    check(`keys`, `[5,6]`, [`[0,1]`]);
    check(`has("a"), has("z")`, `{"a":1}`, [`true`, `false`]);
    check(`has(1.5), has(-1), has(2)`, `[1,2]`, [`true`, `false`, `false`]);
    check(`map(type)`, `[null,true,1,"s",[],{}]`, [`["null","boolean","number","string","array","object"]`]);
    check(`add`, `[[1],[2,3]]`, [`[1,2,3]`]);
    check(`add`, `[]`, [`null`]);
    check(`add`, `{"a":1,"b":2}`, [`3`]);
    check(`map(select(. > 1))`, `[1,2,3]`, [`[2,3]`]);
    check(`sort`, `[3,"a",null,[1],{},true,false,1]`, [`[null,false,true,1,3,"a",[1],{}]`]);
    check(`sort_by(.a, .b)`, `[{"a":2,"b":1},{"a":1,"b":2},{"a":1,"b":1}]`,
            [`[{"a":1,"b":1},{"a":1,"b":2},{"a":2,"b":1}]`]);
    check(`group_by(.k) | map(length)`, `[{"k":2},{"k":1},{"k":2}]`, [`[1,2]`]);
    check(`unique`, `[3,1,3,2,1]`, [`[1,2,3]`]);
    check(`reverse`, `null`, [`[]`]);
    check(`min, max`, `[2,1,3,1]`, [`1`, `3`]);
    check(`min, max`, `[]`, [`null`, `null`]);
    check(`map(tostring)`, `[1.5,"s",[1,"a"],null]`, [`["1.5","s","[1,\"a\"]","null"]`]);
    check(`tonumber`, `"x"`, [`error`]);
    check(`not, (1|not)`, `null`, [`true`, `false`]);
}

unittest // documented examples
{
    check(`.users | map(select(.age >= 30 and .active)) | sort_by(.age) | reverse | map({name, age})`,
            `{"users":[{"name":"ann","age":31,"active":true},{"name":"bob","age":45,"active":false},`
            ~ `{"name":"cy","age":30,"active":true},{"name":"di","age":52,"active":true},`
            ~ `{"name":"ed","age":29,"active":true},{"name":"flo","age":31,"active":true}]}`,
            [`[{"name":"di","age":52},{"name":"flo","age":31},{"name":"ann","age":31},{"name":"cy","age":30}]`]);
    check(`reduce .[] as $o ({}; . + {($o.k): $o.v}), (map(.v) | add), sort_by(.k, -.v), `
            ~ `(group_by(.k) | map([.[0].k, length])), (.[0] | keys), (.[2].v / 4)`,
            `[{"k":"b","v":1},{"k":"a","v":2},{"k":"b","v":3}]`,
            [`{"b":3,"a":2}`, `6`, `[{"k":"a","v":2},{"k":"b","v":3},{"k":"b","v":1}]`,
            `[["a",1],["b",2]]`, `["k","v"]`, `0.75`]);
}

unittest // syntax errors and library API
{
    assertThrown!JqSyntaxError(Filter.compile(`.a |`));
    assertThrown!JqSyntaxError(Filter.compile(`nosuchfunction`));
    assertThrown!JsonParseError(parseJson(`{"a":}`));
    auto f = Filter.compile(`.[] | . * 2`);
    assert(f.source == `.[] | . * 2`);
    assert(toJson(f.collect(parseJson(`[1,2]`))[1]) == `4`);
    assertThrown!JqError(Filter.compile(`error`).collect(Value.makeNull()));
}

unittest // laziness: outputs before an error are delivered
{
    int seen;
    try
        Filter.compile(`1, 2, error, 3`).run(Value.makeNull(), (Value) { ++seen; });
    catch (JqError)
    {
    }
    assert(seen == 2);
}

unittest // objects extended by `+` share storage but stay immutable
{
    string doc = `{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6,"g":7,"h":8,"i":9,"j":10,"k":11,"l":12,"m":13,"n":14}`;
    auto r = run(`. as $o | ($o + {x:1}) as $p | ($o + {y:2}) as $q | ($p + {z:3}) as $s | ($p + {w:4}) as $t `
            ~ `| [($o|length), ($p|keys|length), ($q|has("x")), ($q|has("y")), ($s|has("w")), ($t|has("z")), ($t|has("x")), ($s|length)]`, doc);
    assert(r == [`[14,15,false,true,false,false,true,16]`], r.join(" "));
}
