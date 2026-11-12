"""Filter semantics, table-driven: (filter, document, expected output lines)."""

import pytest

import jqlite
from jqlite import JQError, dumps, loads


def evaluate(filt, doc):
    out = []
    try:
        for v in jqlite.run(filt, doc):
            out.append(dumps(v))
    except JQError:
        out.append("error")
    return out


CASES = [
    # paths
    (".", '{"b":1,"a":[1,2.5]}', ['{"b":1,"a":[1,2.5]}']),
    (".a.b", '{"a":{"b":3}}', ["3"]),
    (".a.b.c", '{"a":null}', ["null"]),
    ('."a b"', '{"a b":1}', ["1"]),
    (".[-1], .[5]", "[1,2,3]", ["3", "null"]),
    (".[1:], .[:-1], .[-2:5]", "[1,2,3]", ["[2,3]", "[1,2]", "[2,3]"]),
    (".[1:3]", '"héllo"', ['"él"']),
    (".[2:1]", "[1,2,3]", ["[]"]),
    (".[]", '{"b":1,"a":2}', ["1", "2"]),
    ("([1,2],[3,4])[(0,1)]", "null", ["1", "3", "2", "4"]),
    # generators and ordering
    ("[(1,2) + (10,20)]", "null", ["[11,12,21,22]"]),
    ("{a:(1,2), b:(3,4)}", "null",
     ['{"a":1,"b":3}', '{"a":1,"b":4}', '{"a":2,"b":3}', '{"a":2,"b":4}']),
    ("1, 2 | . * 10", "null", ["10", "20"]),
    ("[.[] | (., 0)]", "[1]", ["[1,0]"]),
    # operators
    ("[1 - -1, 2 * -3, 7 % -3, -7 % 3, 5.5 % 2]", "null", ["[2,-6,1,-1,1]"]),
    ('"a,b,,c" / ",", ("" / ","), ("abc" / "")', "null",
     ['["a","b","","c"]', "[]", '["a","b","c"]']),
    ('"ab" * 2, ("ab" * 0), ("ab" * -1), (2 * "x")', "null", ['"abab"', '""', "null", '"xx"']),
    ("{} + {a:1} | . + {b:2}", "null", ['{"a":1,"b":2}']),
    ('{"z":1,"a":2} + {"m":3,"z":9}', "null", ['{"z":9,"a":2,"m":3}']),
    ('{"a":{"x":1,"y":2}} * {"a":{"y":3},"b":1}', "null", ['{"a":{"x":1,"y":3},"b":1}']),
    ("[1,2,1,3] - [1]", "null", ["[2,3]"]),
    ("null + 1, 1 + null, (null + null)", "null", ["1", "1", "null"]),
    ("1 == (1.5 - 0.5), ([1,{a:1,b:2}] == [1,{b:2,a:1}])", "null", ["true", "true"]),
    ('[null,false,true,0,"a",[],{}] | sort', "null", ['[null,false,true,0,"a",[],{}]']),
    ('[1 < 2, "a" < "b", [] < {}, null < false, 2 >= 2, 1 != 1]', "null",
     ["[true,true,true,true,true,false]"]),
    # logic
    ("[true and false, false or true, null and error, true or error]", "null",
     ["[false,true,false,true]"]),
    ("[(true,false) and (true,false)]", "null", ["[true,false,false]"]),
    ("[.[] | not]", "[null,false,0,[]]", ["[true,true,false,false]"]),
    ("if . > 1 then 1 elif . > 0 then 2 else 3 end", "[]", ["1"]),  # arrays sort after numbers
    ('[.[] | if . == 1 then "a" elif . == 2 then "b" else "c" end]', "[1,2,3]", ['["a","b","c"]']),
    ("[.[] | if . > 1 then 1 end]", "[1,2]", ["[1,1]"]),
    # variables and reduce
    (". as $x | [$x, $x]", "1", ["[1,1]"]),
    ("(1,2) as $x | $x * 10", "null", ["10", "20"]),
    (".[] as $x | .[] as $y | $x + $y", "[1,2]", ["2", "3", "3", "4"]),
    ("1 as $x | 2 as $x | $x", "null", ["2"]),
    ("reduce .[] as $x (0; . + $x)", "[1,2,3]", ["6"]),
    ("reduce .[] as $x (0; empty)", "[1,2]", ["null"]),
    ("reduce .[] as $x (0; ., 10)", "[1]", ["10"]),
    ("reduce empty as $x (5; . + 1)", "null", ["5"]),
    ("reduce .[] as $o ({}; . + {($o.k): $o.v})", '[{"k":"b","v":1},{"k":"a","v":2}]',
     ['{"b":1,"a":2}']),
    # construction
    ("{a, b}", '{"a":1,"b":2,"c":3}', ['{"a":1,"b":2}']),
    ('{"a b"}, {$x}'.replace("{$x}", "(1 as $x | {$x})"), '{"a b":1}', ['{"a b":1}', '{"x":1}']),
    ("{a:1,b:2,a:3}", "null", ['{"a":3,"b":2}']),
    ("{(.k): -.v}", '{"k":"q","v":2}', ['{"q":-2}']),
    ("{a: .x | .y}", '{"x":{"y":5}}', ['{"a":5}']),
    ("[]", "null", ["[]"]),
    ("[.[] | select(. > 1)]", "[1,2,3]", ["[2,3]"]),
    ("{a:(1,2)}", "null", ['{"a":1}', '{"a":2}']),
    # optional
    (".a?", "5", []),
    (".a.b?", "5", ["error"]),
    ("[([1],2,[3])[0]?]", "null", ["[1,3]"]),
    ("[(1,[2],3)[]?]", "null", ["[2]"]),
    ("[(1,2,error,3)?]", "null", ["[1,2]"]),
    ("(.a.b)?", "5", []),
    ("[.[] | tonumber?]", '["1","x",""," 2","3.5"]', ["[1,3.5]"]),
    ("(1,2)? | error", "null", ["error"]),
    ("[.[1:]?]", "5", ["[]"]),
    ("[.a??]", "5", ["[]"]),
    # builtins
    ("length", '[1,2]', ["2"]),
    ("[.[] | length]", '[null,-3,"héé",[1],{"a":1}]', ["[0,3,3,1,1]"]),
    ("keys, (.[0] | keys)", '[{"b":1,"a":2}]', ["[0]", '["a","b"]']),
    ('[has("a"), has("z")], ([1,2] | has(1, 2, -1, 1.5)), (null | has(1))', '{"a":1}',
     ["[true,false]", "true", "false", "false", "true", "false"]),
    ("[.[] | type]", '[null,true,1,"a",[],{}]',
     ['["null","boolean","number","string","array","object"]']),
    ("add", '[[1],[2,3],null,[]]', ["[1,2,3]"]),
    ("add", '["a","b","c"]', ['"abc"']),
    ("add", '[{"a":1},{"b":2},{"a":3}]', ['{"a":3,"b":2}']),
    ("add, ({} | add), ([] | add)", '{"a":1,"b":2}', ["3", "null", "null"]),
    ("map(. * 2), (map(.) | length)", "[1,2]", ["[2,4]", "2"]),
    ("map(.[]?)", "[[1,2],3,[4]]", ["[1,2,4]"]),
    ("map(select(.a)) | length", '[{"a":0},{"a":null},{"a":false},{}]', ["1"]),
    ("sort_by(.a, .b)", '[{"a":2,"b":1},{"a":1,"b":2},{"a":1,"b":1}]',
     ['[{"a":1,"b":1},{"a":1,"b":2},{"a":2,"b":1}]']),
    ("sort_by(-.n)", '[{"n":0,"i":1},{"n":0,"i":2},{"n":2,"i":3}]',
     ['[{"n":2,"i":3},{"n":0,"i":1},{"n":0,"i":2}]']),
    ("group_by(.k) | map(length)", '[{"k":"b"},{"k":"a"},{"k":"b"}]', ["[1,2]"]),
    ("unique", "[3,1,2,1,3]", ["[1,2,3]"]),
    ("reverse, (null | reverse)", "[1,2,3]", ["[3,2,1]", "[]"]),
    ("min, max", "[]", ["null", "null"]),
    ("min, max", "[3,1,2]", ["1", "3"]),
    ("max", '[{"a":1,"b":2},{"b":2,"a":1}]', ['{"b":2,"a":1}']),
    ("min", '[{"a":1,"b":2},{"b":2,"a":1}]', ['{"a":1,"b":2}']),
    ('[.[] | tostring]', '[1,"a",[1,{"a":2.5}],null]', ['["1","a","[1,{\\"a\\":2.5}]","null"]']),
    ('[("12","-2.5","0") | tonumber]', "null", ["[12,-2.5,0]"]),
    ("[empty, 1, empty]", "null", ["[1]"]),
    ("error(1), 2", "null", ["error"]),
    ("[error(empty)]", "null", ["[]"]),
    ("[.[] | select(. > 1)] | length", "[1,2,3]", ["2"]),
    # errors
    ("1, error, 2", "null", ["1", "error"]),
    (".a", "[1]", ["error"]),
    (".[0]", '{"a":1}', ["error"]),
    (".[null]", "null", ["error"]),
    (".[]", "null", ["error"]),
    ("1 / 0", "null", ["error"]),
    ("1 % 0.5", "null", ["error"]),
    ("1 + \"a\"", "null", ["error"]),
    ("null - 1", "null", ["error"]),
    ("-\"a\"", "null", ["error"]),
    ("true | length", "null", ["error"]),
    ("{(1): 2}", "null", ["error"]),
    ("null | keys", "null", ["error"]),
    ("sort", '"x"', ["error"]),
    ('"abc" | reverse', "null", ["error"]),
    ("[.[] | tonumber]", '["1","x"]', ["error"]),
    ("[1,2] | .[0:1] | .[0] | .x", "null", ["error"]),
]


@pytest.mark.parametrize("filt,doc,expected", CASES, ids=[c[0] for c in CASES])
def test_filter(filt, doc, expected):
    assert evaluate(filt, doc) == expected


def test_spec_example_1():
    doc = ('{"users":[{"name":"ann","age":31,"active":true},{"name":"bob","age":45,"active":false},'
           '{"name":"cy","age":30,"active":true},{"name":"di","age":52,"active":true},'
           '{"name":"ed","age":29,"active":true},{"name":"flo","age":31,"active":true}]}')
    f = (".users | map(select(.age >= 30 and .active)) | sort_by(.age) | reverse"
         " | map({name, age})")
    assert evaluate(f, doc) == [
        '[{"name":"di","age":52},{"name":"flo","age":31},{"name":"ann","age":31},{"name":"cy","age":30}]']


def test_spec_example_2():
    f = "[(1,2) + (10,20)], {a:(1,2), b:(3,4)}, [.[] | .a?], (.[] | .a.b?)"
    assert evaluate(f, '[{"a":{"b":1}},{"a":5},3]') == [
        "[11,12,21,22]", '{"a":1,"b":3}', '{"a":1,"b":4}', '{"a":2,"b":3}', '{"a":2,"b":4}',
        '[{"b":1},5]', "1", "error"]


def test_spec_example_3():
    f = ("reduce .[] as $o ({}; . + {($o.k): $o.v}), (map(.v) | add), sort_by(.k, -.v),"
         " (group_by(.k) | map([.[0].k, length])), (.[0] | keys), (.[2].v / 4)")
    assert evaluate(f, '[{"k":"b","v":1},{"k":"a","v":2},{"k":"b","v":3}]') == [
        '{"b":3,"a":2}', "6", '[{"k":"a","v":2},{"k":"b","v":3},{"k":"b","v":1}]',
        '[["a",1],["b",2]]', '["k","v"]', "0.75"]


def test_filter_object_is_reusable_and_lazy():
    f = jqlite.compile(".[] | if . == 2 then error else . end")
    it = f.run(loads("[1,2,3]"))
    assert next(it) == 1.0
    with pytest.raises(JQError):
        next(it)
    assert list(f.run_text("[1]")) == ["1"]


def test_values_are_not_mutated():
    doc = loads('{"a":[1],"o":{"x":1}}')
    list(jqlite.compile(".a + [2], .o + {y:2}, .o * {x:{z:1}}, add?").run(doc))
    assert dumps(doc) == '{"a":[1],"o":{"x":1}}'


def test_syntax_error():
    with pytest.raises(jqlite.JQSyntaxError):
        jqlite.compile("1 +")
    with pytest.raises(jqlite.JQSyntaxError):
        jqlite.compile("nosuchbuiltin")
