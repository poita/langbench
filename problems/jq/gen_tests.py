#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `jq` problem.

Every test is an embedded (filter, document) pair or comes from a seeded
generator, so re-running this script reproduces the suite exactly. Expected
outputs come from reference/main.py and every one of them is cross-checked
against the real jq binary (`jq -c`, jq 1.7.x); any disagreement aborts.
Every number in every expected output is also checked against the printing
restrictions promised by SPEC.md.
"""
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
REF = os.path.join(HERE, 'reference', 'main.py')
JQ = shutil.which('jq') or '/opt/homebrew/bin/jq'

cases = []


def add(name, filt, doc):
    """Registers a test; doc is JSON text (or a value to be serialized)."""
    if not isinstance(doc, str):
        doc = json.dumps(doc, ensure_ascii=False, separators=(',', ':'))
    assert '\n' not in filt
    cases.append((name, filt, doc))


# ---------------------------------------------------------------------------
# Basic access
# ---------------------------------------------------------------------------
add('identity_scalar', '.', '42')
add('identity_object_key_order', '.',
    '{"zeta": [1, 2.5, "x"], "alpha": {"c": null, "d": true, "b": false}, "": []}')
add('field_access', '.name, .age, .address.city',
    '{"name":"Ada","age":36,"address":{"city":"London","zip":"N1"}}')
add('nested_missing_is_null', '.a.b.c, .x, .a.q.r.s, (.a.b | .z)', '{"a":{"b":{}}}')
add('quoted_fields', '."a b"."c-d", .["a b"]["c-d"], (."a b" | keys), (."a b" | ."e")',
    '{"a b":{"c-d":7,"e":8}}')
add('index_negative_out_of_range', '.[0], .[-1], .[5], .[-4], .[2], .[-3]', '[10,20,30]')
add('slices', '.[1:3], .[:2], .[-2:], .[2:1], .[1:], .[:-1], .[10:], .[-10:2], .[2:2]', '[0,1,2,3,4]')
add('string_slice_unicode', '.[1:3], .[-2:], .[3:], length, .[:1]', '"héllo😀!"')
add('iterate_array', '.[]', '[1,"a",null,[2],{"b":3}]')
add('iterate_object_values', '.[], [.[]], (.[] | type)', '{"x":1,"y":[2],"z":{"k":"v"},"w":null}')
add('pipe_comma_precedence', '1, 2 | . * 10', 'null')
add('comma_in_pipe', '[.[] | ., . * 2], (.[] | ., "sep")', '[1,2]')
add('literals', '[1, "two", true, null, [3], {a: 1, "b c": [2]}], {}, [], 1.5, "", -3, 0', 'null')
add('object_construction_forms',
    '. as $x | {a, "b", $x, (.c + "_k"): .d, e: (.a | .f), f: .a.f, g: -1, h: .a | .f, i: {j: [.d[]]}}',
    '{"a":{"f":7},"b":2,"c":"key","d":[1,2]}')
add('object_duplicate_keys_and_order', '{b: 1, a: 2, b: 3}, {b, a}, ({b:1} + {a:2}), ({"z":1,"a":2} + {"m":3,"z":9})',
    '{"a":1,"b":2}')

# ---------------------------------------------------------------------------
# Arithmetic, comparison, logic
# ---------------------------------------------------------------------------
add('arithmetic_numbers',
    '[1 + 2 * 3 - 4 / 2 % 3, 10 / 4, -7 / 2, 7 % 3, -7 % 3, 7 % -3, 5.5 % 2, -5.5 % 2, 5 % 2.9, '
    '2 * -3, 1 - -1, 3 - 1 - 1, 8 / 2 / 2, 1.5 + 1.5, 0.5 * 0.5, 100 * 100, 0.001 * 1000, 7 / 7, -.a, -(.a + 1), - .b * 2]',
    '{"a":3,"b":1.5}')
add('arithmetic_strings_arrays_objects',
    '[("a" + "b"), ("ab" * 3), (3 * "ab"), ("ab" * 0), ("ab" * -1), ("a,b,,c" / ","), ("" / ","), ("abc" / ""), '
    '("a" / "a"), ([1] + [2,3]), ([1,2,3,2,[2],{"a":1}] - [2,[2],{"a":1}]), ({"a":1,"b":2} + {"b":3,"c":4}), '
    '({"a":{"x":1,"y":2},"q":0} * {"a":{"z":3,"x":9},"b":1}), ({"a":{"x":1}} * {"a":5}), ({"a":5} * {"a":{"x":1}}), '
    '(null + 1), (1 + null), (null + null), ("a" + null), (null + [1]), ({} + null)]', 'null')
add('comparisons_mixed_types',
    '[1 == (1.5 - 0.5), [1,2] == [1,2], ({"a":1,"b":2} == {"b":2,"a":1}), (1 == "1"), (null == false), ([1] < [1,0]), '
    '("a" < "b"), ("Z" < "a"), ("é" > "z"), ("" < "a"), ("ab" < "b"), ({} < []), ([] < {}), (null < false), '
    '(false < true), (true < 0), (-1 < ""), (1 != 1), (2 >= 2), (2 <= 1), ({"a":1} < {"a":2}), ({"a":2} < {"b":1}), '
    '({"a":1,"b":1} > {"a":1}), ([[1]] > [[0,9]]), (.a == .b), (.a < .c)]',
    '{"a":[1,{"k":"v"}],"b":[1,{"k":"v"}],"c":[1,{"k":"w"}]}')
add('sort_mixed_types', 'sort',
    '[{"b":1},{"a":2},[1],"b","a",true,false,null,2,1,-1,{"a":1,"b":0},{"a":1},[0,1],[],[1,0],'
    '{"b":0,"a":1},{"a":2,"b":-1},"B","aa","é","",0.5,[[]],[null],{"":0}]')
add('and_or_not',
    '[(true,false) and (true,false)], [(false,true) or (false,true)], [false and error, true or error], '
    '[not, (0|not), (""|not), ([]|not), (null|not), (false|not)], [1 < 2 and 2 < 3 or false, (null and true), (1 or false)]',
    '1')
add('if_elif_else',
    '[.[] | if . > 1 then "big" elif . > 0 then "small" elif . == 0 then "zero" else "neg" end], '
    '[if (true,false) then 1 end], [if (true,false) then 1 else 2 end], (if .[0] then "t" else "f" end), '
    '[.[] | if . then 1 end], (if (.[] | . > 0) then "y" else "n" end)',
    '[2,1,0,-1,null,false,"s"]')

# ---------------------------------------------------------------------------
# Generators and evaluation order
# ---------------------------------------------------------------------------
add('generators_cartesian_order',
    '[(1,2) + (10,20)], [(1,2) < (10,20)], [{a:(1,2), b:(3,4)}], [{(("a","b")): (1,2)}], [([1,2],[3,4])[(0,1)]], '
    '[.[(0,1)]], [[0,1,2,3][(0,1):(2,3)]], [([0,1,2],[5,6,7])[(0,1):2]], [([0,1,2],[5,6,7])[1:(2,3)]], '
    '[.[] as $x | .[] as $y | [$x,$y]], [(1,2) - (10,20)], [(1,2) * (3,4)], [(true,false) == (false,true)]',
    '[1,2]')
add('optional_per_operation',
    '[.[] | .a?], [.[] | .[0]?], [.[]?], [.[] | (.a.b)?], [.[("a",0,"b")]?], [([1],2,[3])[0]?], [(1,[2],3)[]?], '
    '[(1,2,error,3)?], [error(null)?], [.[] | .a?.b?], [.[] | tonumber?], [.[] | .[1:]?], [(.[0].a, .[1].a)?], [.a??]',
    '[{"a":{"b":1}},{"a":5},3,null,"x",[7],"12"]')
add('optional_only_last_op', '[.[] | .a.b?]', '[{"a":{"b":1}},{"a":5},3]')
add('try_scope_downstream_error', '[(1,2)?], (.[] | (.x)?), ((1,2)? | error)', '[{"x":1},2]')
add('variables_scoping',
    '. as $x | 1 as $y | [$x, $y, (2 as $y | $y), $y], ($x | .a), ($x.a + $y), [.b[] as $e | $e * $y], ($x.b[0] as $y | $y)',
    '{"a":10,"b":[1,2]}')
add('as_binding_generators',
    '[.[] as $x | $x * 2], ((.[] | select(. > 1)) as $x | $x * 2), [.[] as $x | .[] as $y | select($x < $y) | [$x, $y]], '
    '[(.[] | select(. > 5)) as $x | $x]',
    '[1,2,3]')
add('reduce_forms',
    'reduce .[] as $x (0; . + $x), reduce .[] as $x ([]; [$x] + .), reduce .[] as $x (0; . + 1), '
    'reduce (1,2) as $x ((0,10); . + $x), reduce (1,2,3) as $x (0; if $x == 2 then empty else . + $x end), '
    'reduce empty as $x (5; . + 1), reduce .[] as $x (0; (. + $x, . * 10)), reduce .[] as $x (null; . + $x)',
    '[1,2,3,4.5]')
add('reduce_build_object', 'reduce .[] as $o ({}; . + {($o.k): $o.v}), reduce .[] as $o ({}; . * {($o.k): {n: $o.v}})',
    '[{"k":"b","v":1},{"k":"a","v":2},{"k":"b","v":3}]')
add('empty_everywhere',
    '[1 + empty], [empty], ({a: empty} | 1), [if empty then 1 else 2 end], [select(empty)], [.[] | empty], '
    '[empty, 1, empty, 2], [error(empty)], [(empty)?], [.[] | select(. > 1) | empty], 9',
    '[1,2,3]')

# ---------------------------------------------------------------------------
# Builtins
# ---------------------------------------------------------------------------
add('select_map', 'map(. + 1), [.[] | select(. > 1, . < 3)], [.[] | select(. > 1)], map(select(. != 2)), '
    '(map(. * 2) | add), [.[] | select(true, false)]', '[1,2,3]')
add('map_on_object', 'map(. + 1), map(type), [.[] | select(. > 1)]', '{"a":1,"b":2,"c":3}')
add('object_iteration_insertion_order',
    'add, map(.), [.[]], (map(. + "!") | add), (.[] | length), ({"z":[1],"a":[2],"m":[0]} | add), ({"b":{"x":1},"a":{"x":2,"y":3}} | add), keys',
    '{"c":"x","a":"y","b":"z"}')
add('select_truthiness', '[.[] | select(.a)], [.[] | select(.a | not)], map(select(has("a")))',
    '[{"a":true},{"a":null},{"a":0},{},{"a":false},{"a":""},{"a":[]}]')
add('keys_has_length_type',
    'keys, (.arr | keys), ([has("a"), has("zz")]), (.arr | [has(0), has(2), has(-1), has(3)]), '
    '[.[] | length], [.[] | type], ({} | keys), ([] | keys), ("" | length), (null | length), (-2.5 | length), ("😀é" | length), [.n | has("a"), has(0), has(null)], [.q | has("a")], (.arr | [has(0.5), has(1.5)])',
    '{"b":1,"a":"héllo","arr":[1,[2,3],{"x":1}],"n":null,"neg":-4}')
add('keys_unicode_order', 'keys, (keys | .[0]), (.to_sort | sort), ([.[] ] | sort)',
    '{"b":1,"a":2,"é":3,"B":4,"aa":5,"":6,"Z":0,"z":9,"日":1,"ab":7,"to_sort":["b","é","B","","日","a","aa","ab"]}')
add('add_variants',
    '[(.nums | add), (.strs | add), (.arrs | add), (.objs | add), (.nulls | add), ([] | add), ({"a":1,"b":2} | add), '
    '({"a":"x","b":"y"} | add), ([[1],null,[2]] | add), ([null,1] | add), ([1,null] | add), (.mixed | add)]',
    '{"nums":[1,2,3.5],"strs":["a","b","c"],"arrs":[[1],[2,3],[]],"objs":[{"a":1},{"b":2},{"a":3}],"nulls":[null,null],"mixed":[null,[1],[2]]}')
add('sort_by_group_by',
    'sort_by(.a), sort_by(.a, .b), sort_by(.b) , group_by(.a), (group_by(.a) | map(length)), sort_by(-.b), '
    '(group_by(.b > 1) | map(map(.i)))',
    '[{"a":1,"b":2,"i":0},{"a":null,"b":1,"i":1},{"b":3,"i":2},{"a":1,"b":1,"i":3},{"a":"1","b":2,"i":4},{"a":[0],"b":0,"i":5},{"a":0,"b":2,"i":6}]')
add('stable_sort_and_ties',
    'sort_by(.x), (sort_by(.x) | reverse), sort, unique, min, max, (map(.x) | unique), group_by(.x)',
    '[{"x":1,"y":"a"},{"x":0},{"x":1,"y":"b"},{"y":"c"},{"x":0},{"x":1,"y":"a"}]')
add('min_max_unique_reverse',
    '[.[] | min], [.[] | max], [.[] | unique], [.[] | reverse], ([] | min, max, unique, reverse), (null | reverse), '
    '([{"a":1,"b":2},{"b":2,"a":1}] | min, max, unique, (sort | .[0]))',
    '[[3,1,2],[[1],"a",null,{}],[1,"1",[1],1,null,1.5,{"a":1},{"a":1},1],["b","a","b"]]')
add('group_by_objects',
    '.users | group_by(.dept) | map({dept: .[0].dept, count: length, total: (map(.salary) | add), names: (map(.name) | sort)})',
    '{"users":[{"name":"c","dept":"eng","salary":120},{"name":"a","dept":"ops","salary":90},{"name":"b","dept":"eng","salary":110},'
    '{"name":"d","salary":50},{"name":"e","dept":"ops","salary":95},{"name":"f","dept":null,"salary":1}]}')
add('tostring_tonumber',
    '[.[] | tostring], [.[] | tostring | type], [.[] | tonumber?], ({"k":[1,{"z":"q"}]} | tostring), (.[0] | tostring | tonumber), [.[7:] | .[] | tonumber?]',
    '[1.5,true,null,"s",[1,"a"],{"b":[],"a":{}},-3,"0","-0.5","12","3.25","x",""]')
add('tonumber_strings', '[.[] | tonumber?], (.[0] | tonumber | . + 1), (.[3] | tonumber | . * 2)',
    '["10","-2.5","abc","3.5","","12abc","0","1.0.0"]')
add('string_escapes_and_unicode',
    '.[], (.[0] | length), "a\\"b\\\\c\\n\\t\\u00e9\\/z", ("x" + .[1]), [.[] | length], (.[2] | . + "\\u0007"), .[3]',
    '["a\\"b\\\\c\\n\\t\\u0001\\u001f\\u007f/é日本😀", "\\u2028\\u00e9", "\\b\\f\\r", "\\ud83d\\ude00"]')
add('string_order_astral_vs_bmp',
    'sort, keys, (.[0] < .[1]), (.[2] > .[3]), unique, (group_by(.[0:1]) | map(length)), (sort_by(.) | .[-1] | length), (map(. + "!") | max)',
    '["\\ud83d\\ude00", "\\uffff", "\\ue000z", "\\ud7ffz", "\\ud83d\\ude00a", "\\ud83d\\ude00", "\\ufffd", "z", "\\u65e5"]')
add('numbers_format',
    '[.[] | . * 2], [.[] | . / 4], [1.5 + 1.5, 2.5 * 2, 0.5 / 0.5, 1.25 - 0.25, 100 * 100, 0.001 * 1000, 3.75 - 1.5, 1000000 * 1000000], '
    '[.[] | . + 1], [.[] | . - .], (.[1] | tostring), [.[] | . == 3], 9007199254740991, -9007199254740991, (.[5] | length)',
    '[1.5, 2.25, 0.5, 3, 1000000, -0.125, 0.004, 123456.789012, 12345678901234, 1234567.5]')

# ---------------------------------------------------------------------------
# Errors: results before the error are printed, then "error"
# ---------------------------------------------------------------------------
add('error_partial_output', '.[] | if . == 2 then error else . end', '[1,2,3]')
add('error_in_array_construction', '1, [.[] | if . == 2 then error("boom") else . end], 3', '[1,2,3]')
add('error_index_number_with_string', '.a', '5')
add('error_index_string_with_number', '.[0]', '"abc"')
add('error_index_array_with_string', '.[0], .["a"]', '[1]')
add('error_iterate_null', '[.a?], .a, .[]', 'null')
add('error_div_zero', '10 / 5, 1 / 0', 'null')
add('error_mod_zero', '5 % 0.5', 'null')
add('error_add_types', '[1,"a"] | add', 'null')
add('error_sort_non_array', '"abc" | sort', 'null')
add('error_has_type_mismatch', '.[0] | has("a")', '[[1]]')
add('error_length_boolean', '.[] | length', '[[], "x", 1, true, null]')
add('error_tonumber', '.[] | tonumber', '["1", "2.5", "x", "3"]')
add('error_object_key_not_string', '{(.k): 1}', '{"k":5}')
add('error_message_object', '.[] | error({msg: .})', '["a"]')
add('error_slice_object', '.[1:2]', '{"a":1}')
add('error_string_reverse', '.[] | reverse', '[[1,2],null,"ab"]')
add('error_subtract_null', '[.[] | . - 1]', '[3, 2, null]')
add('error_map_non_iterable', '.[] | map(. + 1)', '[[1],{"a":2},3]')
add('error_negate_string', '-.a, -.b', '{"a":1,"b":"x"}')
add('error_keys_null', '.a | keys', '{}')
add('error_index_null_with_null', '.[null]', 'null')
add('error_inside_reduce', 'reduce .[] as $x (0; . + $x)', '[1,2,"3"]')
add('error_null_message', '1, error(null), 2', '[]')
add('error_caught_by_optional_then_uncaught', '[.[] | (.a)?], (.[] | .a)', '[{"a":1}, 2]')

# ---------------------------------------------------------------------------
# Structural / realistic
# ---------------------------------------------------------------------------
deep = '{"a":' * 30 + '[1,2,{"b":"deep"}]' + '}' * 30
add('deep_nesting', '.a' * 30 + '[2].b, (' + '.a' * 30 + ' | length), ' + '.a' * 31 + '?, ([' + '.a' * 30 + '[]] | length)', deep)
add('realistic_pipeline',
    '.users | map(select(.age >= 30 and .active)) | sort_by(.age) | reverse | map({name, age})',
    '{"users":[{"name":"ann","age":31,"active":true},{"name":"bob","age":45,"active":false},{"name":"cy","age":30,"active":true},'
    '{"name":"di","age":52,"active":true},{"name":"ed","age":29,"active":true},{"name":"flo","age":31,"active":true}]}')
add('realistic_tags',
    '[.[] | select(.active) | .tags[]] | group_by(.) | map({tag: .[0], n: length}) | sort_by(-.n, .tag)',
    '[{"active":true,"tags":["a","b"]},{"active":false,"tags":["a"]},{"active":true,"tags":["b","c","b"]},{"active":true,"tags":[]}]')
add('realistic_invoice',
    '.items | (map(.price * .qty) | add), (.[0] | keys), map(select(.qty > 1) | .sku), (map(.qty) | add), (map(.price) | max)',
    '{"items":[{"sku":"A1","price":2.5,"qty":4},{"sku":"B2","price":10,"qty":1},{"sku":"C3","price":0.25,"qty":8}]}')
add('nested_paths_on_missing',
    '.a.b.c, .a.b[0].c, .x[1:2], .a.b?, [.q[]?], .a.b.c[0], .a["b"].c, (.a | .b | .c | .d), .["missing"].y, .a.b.c[1:]',
    '{"a":{"b":null}}')
add('key_order_preserved_through_ops',
    '.[0] + .[1], .[0] * .[1], ([.[] | keys]), (.[0] | {(keys[]): 1}), (map(.z) | add), (.[1] | .[]), sort',
    '[{"z":1,"y":{"q":1,"p":2},"x":3},{"y":{"p":9,"r":0},"a":0,"z":5}]')


# ---------------------------------------------------------------------------
# Generated documents
# ---------------------------------------------------------------------------
FIRST = ['ann', 'bob', 'cy', 'di', 'ed', 'flo', 'gus', 'hal', 'ivy', 'jo', 'kim', 'lee', 'max', 'ned', 'oz',
         'pat', 'quin', 'rae', 'sal', 'tom', 'uma', 'vic', 'wes', 'xi', 'yan', 'zed', 'émile', '日向', 'Zoë', 'Ólafur']
DEPTS = ['eng', 'ops', 'sales', 'hr', 'legal', None]
CITIES = ['Paris', 'Oslo', 'Tokyo', 'Lima', 'Cairo', 'Perth', 'Quito', 'Rome']
TAGS = ['red', 'green', 'blue', 'gold', 'new', 'vip', 'beta', 'x', 'y']


def canonical_cents(cents):
    """cents/100 as a number that json.dumps prints canonically (no `.0`)."""
    return cents // 100 if cents % 100 == 0 else cents / 100


def gen_record(rng, i):
    tags = rng.sample(TAGS, rng.randint(0, 4))
    rec = {
        'id': i,
        'name': rng.choice(FIRST) + '_' + str(i),
        'age': rng.randint(18, 80),
        'active': rng.random() < 0.6,
        'dept': rng.choice(DEPTS),
        'score': rng.randint(0, 100),
        'balance': canonical_cents(rng.randint(-5000, 500000)),
        'tags': tags,
        'address': {'city': rng.choice(CITIES), 'zip': '%05d' % rng.randint(0, 99999), 'geo': [rng.randint(-90, 90), rng.randint(-180, 180)]},
        'manager': None if rng.random() < 0.3 else {'id': rng.randint(0, i), 'level': rng.randint(1, 5)},
    }
    if rng.random() < 0.1:
        del rec['dept']
    if rng.random() < 0.05:
        rec['notes'] = 'line1\nline2\t"quoted" \\ end'
    return rec


def gen_records(seed, count):
    rng = random.Random(seed)
    return [gen_record(rng, i) for i in range(count)]


def compact(v):
    return json.dumps(v, ensure_ascii=False, separators=(',', ':'))


def pretty(v):
    return json.dumps(v, ensure_ascii=False, indent=2)


small = gen_records(1, 40)
add('gen_small_select_fields', '.[] | select(.active and .age > 40) | {id, name, city: .address.city}', pretty(small))
add('gen_small_group_dept', 'group_by(.dept) | map({dept: .[0].dept, n: length, sum_age: (map(.age) | add), rem: ((map(.age) | add) % length), ids: map(.id)})', compact(small))
add('gen_small_sort_by_multi', 'sort_by(.address.city, -.score, .id) | map([.address.city, .score, .id])', compact(small))
add('gen_small_reduce_stats',
    'reduce .[] as $r ({n: 0, sum: 0, max: null}; {n: (.n + 1), sum: (.sum + $r.score), max: (if .max == null or $r.score > .max then $r.score else .max end)})',
    compact(small))
add('gen_small_tags_unique', '([.[] | .tags[]] | unique), ([.[] | .tags | length] | add), ([.[] | select(.tags | has(2)) | .id])', compact(small))
add('gen_small_managers', '([.[] | select(.manager) | .manager.level] | group_by(.) | map([.[0], length])), ([.[] | .manager.id?] | map(select(. != null)) | sort | .[0:5])', compact(small))
add('gen_small_tostring_keys', '(map({(.id | tostring): .name}) | add | keys | .[0:10]), (map(.balance) | sort | .[0], .[-1]), (map(.balance) | max)', compact(small))
add('gen_small_optional_errors', '[.[] | .address.geo[0]?], [.[] | .manager.level?], ([.[] | .notes?] | map(select(. != null))), (.[] | select(.id == 7) | .tags | .[0] | .x)', compact(small))

medium = gen_records(2, 2000)
add('gen_medium_filter_ids', '[.[] | select(.score > 50 and (.dept == "eng" or .dept == "ops")) | .id] | length, .[0:20]', compact(medium))
add('gen_medium_city_stats', 'group_by(.address.city) | map({city: .[0].address.city, n: length, top: (sort_by(-.score, .id) | .[0].name), active: (map(select(.active)) | length)})', pretty(medium))
add('gen_medium_many_outputs', '.[] | select(.active) | [.id, .name, .balance * 2]', compact(medium))
add('gen_medium_sort_mixed', '[.[] | .manager, .tags, .dept, .balance, .active, .address.geo] | sort | .[0:15], .[-15:], (unique | length), (group_by(type) | map([.[0] | type, length]))', compact(medium))
add('gen_medium_unique_sorted', '(map(.age) | unique), (map(.tags) | add | unique | length), (map(.manager.id?) | unique | length), (sort_by(.balance) | .[0].id, .[-1].id)', compact(medium))

large = gen_records(3, 25500)
large_text = compact(large)
assert 5_000_000 <= len(large_text.encode('utf-8')) <= 6_000_000, len(large_text.encode('utf-8'))
add('gen_large_map_select', '(map(select(.active and .age > 30) | .name) | length, .[0:5]), (map(select(.dept == "hr") | .score) | add)', large_text)
add('gen_large_iterate_outputs', '.[] | select(.score == 100 and .active) | {id, city: .address.city, tags: (.tags | sort)}', large_text)
add('gen_large_many_outputs', '.[] | select(.age < 60) | [.id, .name, .dept]', large_text)
add('gen_large_sort_group', '(group_by(.dept) | map({dept: .[0].dept, n: length, best: (sort_by(-.score, .id) | .[0].id)})), (sort_by(.balance, .id) | .[0:3] | map(.id)), (map(.score) | add), (reduce .[] as $r (0; . + $r.age))', large_text)


# ---------------------------------------------------------------------------
# Oracle: real jq
# ---------------------------------------------------------------------------
INT_RE = re.compile(r'-?(?:0|[1-9][0-9]*)\Z')
DEC_RE = re.compile(r'-?(?:0|[1-9][0-9]*)\.[0-9]*[1-9]\Z')


def check_number_literal(text):
    """Every number printed must be an integer < 2^53 or a short plain decimal."""
    if INT_RE.match(text):
        assert text != '-0', 'negative zero in output'
        assert abs(int(text)) < 2 ** 53, text
        return
    assert DEC_RE.match(text), 'non-simple number in output: %r' % text
    digits = text.lstrip('-').replace('.', '').lstrip('0')
    assert len(digits) <= 15, text
    assert abs(float(text)) >= 0.001, text


def check_input_numbers(filt, doc):
    """jq 1.7 prints number literals as written, so every literal in the
    filter and the document must already be in the canonical output form."""
    def canon(text):
        check_number_literal(text)
        return 0.0
    json.loads(doc, parse_int=canon, parse_float=canon)
    no_strings = re.sub(r'"(?:[^"\\]|\\.)*"', '""', filt)
    for m in re.finditer(r'(?<![A-Za-z0-9_.$])[0-9]+(?:\.[0-9]+)?(?![0-9.])', no_strings):
        check_number_literal(m.group(0))


def check_output_numbers(out):
    for line in out.split('\n'):
        if line == 'error' or line == '':
            continue
        json.loads(line, parse_int=check_number_literal, parse_float=check_number_literal)


def run_reference(data):
    proc = subprocess.run([sys.executable, REF], input=data, capture_output=True, timeout=600)
    assert proc.returncode == 0, proc.stderr.decode()
    return proc.stdout.decode('utf-8')


def run_jq(filt, doc):
    with tempfile.NamedTemporaryFile('w', suffix='.jq', delete=False, encoding='utf-8') as tf:
        tf.write(filt)
        prog = tf.name
    try:
        proc = subprocess.run([JQ, '-c', '-f', prog], input=doc.encode('utf-8'), capture_output=True, timeout=600)
    finally:
        os.unlink(prog)
    out = proc.stdout.decode('utf-8')
    if proc.returncode == 5:
        out += 'error\n'
    elif proc.returncode != 0:
        raise AssertionError('jq exit %d: %s' % (proc.returncode, proc.stderr.decode()[:300]))
    return out


def normalize(text):
    return '\n'.join(line.rstrip() for line in text.split('\n')).rstrip('\n')


def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith('.in') or f.endswith('.out'):
            os.remove(os.path.join(TESTS, f))
    names = set()
    for idx, (name, filt, doc) in enumerate(cases, 1):
        assert name not in names, name
        names.add(name)
        base = '%03d_%s' % (idx, name)
        data = (filt + '\n' + doc + '\n').encode('utf-8')
        expected = run_reference(data)
        oracle = run_jq(filt, doc)
        if normalize(expected) != normalize(oracle):
            print('MISMATCH in %s\n  filter: %s\n  reference: %r\n  jq:        %r' % (base, filt, expected[:400], oracle[:400]))
            sys.exit(1)
        check_input_numbers(filt, doc)
        check_output_numbers(expected)
        with open(os.path.join(TESTS, base + '.in'), 'wb') as f:
            f.write(data)
        with open(os.path.join(TESTS, base + '.out'), 'w', encoding='utf-8') as f:
            f.write(expected)
        print('ok %s (%d bytes in, %d lines out)' % (base, len(data), expected.count('\n')))
    print('%d tests written' % len(cases))


if __name__ == '__main__':
    main()
