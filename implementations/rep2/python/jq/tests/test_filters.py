"""Table-driven filter semantics: (filter, input JSON, expected outputs as compact JSON)."""

import pytest

from jqlite import JQError, compile_filter, dumps, loads


def outputs(filter_text, doc_text):
    f = compile_filter(filter_text)
    return [dumps(v) for v in f.run(loads(doc_text))]


CASES = [
    # basics
    (".", '{"b":1,"a":2}', ['{"b":1,"a":2}']),
    (".a", '{"a":1}', ["1"]),
    (".a", "null", ["null"]),
    ('."a b"', '{"a b":3}', ["3"]),
    (".[-1]", "[1,2,3]", ["3"]),
    (".[5]", "[1]", ["null"]),
    (".[]", '{"x":1,"y":2}', ["1", "2"]),
    (".[1:]", "[1,2,3]", ["[2,3]"]),
    (".[:-1]", '"héllo"', ['"héll"']),
    (".[2:1]", "[1,2,3]", ["[]"]),
    (".[1:]", "null", ["null"]),
    # generator order
    ("[(1,2) + (10,20)]", "null", ["[11,12,21,22]"]),
    ("{a:(1,2), b:(3,4)}", "null", ['{"a":1,"b":3}', '{"a":1,"b":4}', '{"a":2,"b":3}', '{"a":2,"b":4}']),
    ("([1,2],[3,4])[(0,1)]", "null", ["1", "3", "2", "4"]),
    # optional
    ("[.[] | .a?]", '[{"a":1},5,null]', ["[1,null]"]),
    ("[([1],2,[3])[0]?]", "null", ["[1,3]"]),
    ("[(1,[2],3)[]?]", "null", ["[2]"]),
    (".a?", "5", []),
    ("[(1,2,error,3)?]", "null", ["[1,2]"]),
    ("(.a.b)?", "5", []),
    ("[.[] | tonumber?]", '["1","x","2.5"]', ["[1,2.5]"]),
    # arithmetic
    ("-7 % 3, 7 % -3, 5.5 % 2", "null", ["-1", "1", "1"]),
    ('"ab" * 3, 3 * "ab", "ab" * 0, "ab" * -1', "null", ['"ababab"', '"ababab"', '""', "null"]),
    ('"a,b,,c" / ",", "" / ",", "abc" / ""', "null", ['["a","b","","c"]', "[]", '["a","b","c"]']),
    ("[1,2,3,2] - [2]", "null", ["[1,3]"]),
    ('{"z":1,"a":2} + {"m":3,"z":9}', "null", ['{"z":9,"a":2,"m":3}']),
    ('{"a":{"x":1}} * {"a":{"y":2}}, null + 1, 1 + null', "null", ['{"a":{"x":1,"y":2}}', "1", "1"]),
    ("10 / 4, 1 -1, 2 * -3, 1 - -1", "null", ["2.5", "0", "-6", "2"]),
    ("1 == (1.5 - 0.5), {a:1,b:2} == {b:2,a:1}", "null", ["true", "true"]),
    ("[1,null,false,0,\"\",[],{}] | map(not)", "null", ["[false,true,true,false,false,false,false]"]),
    # logic
    ("false and error, true or error", "null", ["false", "true"]),
    ("(true,false) and (true,false)", "null", ["true", "false", "false"]),
    # control
    ("if . > 1 then \"big\" elif . > 0 then \"pos\" else \"neg\" end", "1", ['"pos"']),
    ("if . then 1 end", "false", ["false"]),
    (".[] as $x | $x * 2", "[1,2]", ["2", "4"]),
    ("1 as $x | 2 as $x | $x", "null", ["2"]),
    ("reduce .[] as $x (0; . + $x)", "[1,2,3]", ["6"]),
    ("reduce empty as $x (0; . + 1)", "null", ["0"]),
    ("reduce .[] as $x (0; empty)", "[1]", ["null"]),
    ("reduce .[] as $o ({}; . + {($o.k): $o.v})", '[{"k":"b","v":1},{"k":"a","v":2},{"k":"b","v":3}]', ['{"b":3,"a":2}']),
    ("{a:1,b:2,a:3}", "null", ['{"a":3,"b":2}']),
    ('{a, "b", $x: 1}'.replace("$x: 1", "c: .a"), '{"a":1,"b":2}', ['{"a":1,"b":2,"c":1}']),
    ("{(\"k\"+\"1\"): .a | (. + 1)}", '{"a":1}', ['{"k1":2}']),
    # builtins
    ("length", '[1,2]', ["2"]),
    ("map(length)", '[null,-3,"héé",[1],{"a":1}]', ["[0,3,3,1,1]"]),
    ("keys", '{"b":1,"a":2}', ['["a","b"]']),
    ("keys", "[5,6]", ["[0,1]"]),
    ("has(\"a\"), has(\"b\")", '{"a":null}', ["true", "false"]),
    ("has(1.5), has(-1), has(2)", "[1,2]", ["true", "false", "false"]),
    ("has(\"a\")", "null", ["false"]),
    ("type", "[]", ['"array"']),
    ("add", "[]", ["null"]),
    ("add", '[[1],[2]]', ["[1,2]"]),
    ("add", '["a","b"]', ['"ab"']),
    ("add", '{"a":1,"b":2}', ["3"]),
    ("add", '[{"a":1},{"b":2},null]', ['{"a":1,"b":2}']),
    ("select(. > 1)", "2", ["2"]),
    ("[.[] | select(. > 1)]", "[1,2,3]", ["[2,3]"]),
    ("sort", '[3,"a",null,[1],{"a":1},true,false,1]', ['[null,false,true,1,3,"a",[1],{"a":1}]']),
    ("sort_by(.a, .b)", '[{"a":1,"b":2},{"a":0,"b":5},{"a":1,"b":1}]', ['[{"a":0,"b":5},{"a":1,"b":1},{"a":1,"b":2}]']),
    ("sort_by(-.n)", '[{"n":0,"i":1},{"n":2,"i":2},{"n":0,"i":3}]', ['[{"n":2,"i":2},{"n":0,"i":1},{"n":0,"i":3}]']),
    ("group_by(.k)", '[{"k":2,"i":1},{"k":1,"i":2},{"k":2,"i":3}]', ['[[{"k":1,"i":2}],[{"k":2,"i":1},{"k":2,"i":3}]]']),
    ("unique", "[3,1,3,2,1]", ["[1,2,3]"]),
    ("reverse, (null | reverse)", "[1,2]", ["[2,1]", "[]"]),
    ("min, max", "[]", ["null", "null"]),
    ("min_by_first".replace("min_by_first", "min"), '[{"a":1,"b":1},{"b":1,"a":1}]', ['{"a":1,"b":1}']),
    ("max", '[{"a":1,"b":1},{"b":1,"a":1}]', ['{"b":1,"a":1}']),
    ("tostring", '[1,"a"]', ['"[1,\\"a\\"]"']),
    ("map(tostring)", '[1,"a",null,{"x":1.5}]', ['["1","a","null","{\\"x\\":1.5}"]']),
    ("map(tonumber)", '["12","-2.5","3.25","0"]', ["[12,-2.5,3.25,0]"]),
    ("empty", "1", []),
    ("[error(empty)]", "1", ["[]"]),
    ("map(select(.a)) | length", '[{"a":0},{"a":null},{"a":false},{}]', ["1"]),
]


@pytest.mark.parametrize("filter_text,doc,expected", CASES, ids=[c[0][:40] for c in CASES])
def test_filter(filter_text, doc, expected):
    assert outputs(filter_text, doc) == expected


ERRORS = [
    ("error", "1"),
    ("error(null)", "1"),
    (".a", "5"),
    (".[0]", '{"a":1}'),
    (".[null]", "null"),
    (".[]", "null"),
    (".[]", "5"),
    ("1 / 0", "null"),
    ("5 % 0.5", "null"),
    ("1 + \"a\"", "null"),
    ("-.", '"a"', ),
    ("{(1): 2}", "null"),
    ("length", "true"),
    ("keys", "1"),
    ("sort", "{}"),
    ("tonumber", '"abc"'),
    ("tonumber", '""'),
    ("reverse", '"abc"'),
    ("add", "5"),
    (".a.b?", "5"),
    ("(1,2)? | error", "null"),
]


@pytest.mark.parametrize("filter_text,doc", ERRORS)
def test_errors(filter_text, doc):
    with pytest.raises(JQError):
        outputs(filter_text, doc)


def test_results_before_error_are_yielded():
    it = compile_filter("1, 2, error, 3").run(None)
    assert next(it) == 1.0 and next(it) == 2.0
    with pytest.raises(JQError):
        next(it)


def test_laziness():
    # `first` output must be available without evaluating the failing tail
    it = compile_filter(".[] | 10 / .").run(loads("[2,0]"))
    assert next(it) == 5.0


def test_filter_reuse_and_values_not_mutated():
    f = compile_filter(". + {c: 3}")
    doc = loads('{"a":1}')
    assert dumps(f.all(doc)[0]) == '{"a":1,"c":3}'
    assert dumps(doc) == '{"a":1}'
    assert dumps(f.all(doc)[0]) == '{"a":1,"c":3}'


def test_moderate_pipe_chain():
    assert outputs(" | ".join(["."] * 200), "1") == ["1"]


def test_spec_examples():
    doc = '{"users":[{"name":"ann","age":31,"active":true},{"name":"bob","age":45,"active":false},{"name":"cy","age":30,"active":true},{"name":"di","age":52,"active":true},{"name":"ed","age":29,"active":true},{"name":"flo","age":31,"active":true}]}'
    out = outputs(".users | map(select(.age >= 30 and .active)) | sort_by(.age) | reverse | map({name, age})", doc)
    assert out == ['[{"name":"di","age":52},{"name":"flo","age":31},{"name":"ann","age":31},{"name":"cy","age":30}]']
    f = compile_filter("[.[] | .a?], (.[] | .a.b?)")
    it = f.run(loads('[{"a":{"b":1}},{"a":5},3]'))
    assert dumps(next(it)) == '[{"b":1},5]'
    assert dumps(next(it)) == "1"
    with pytest.raises(JQError):
        next(it)
