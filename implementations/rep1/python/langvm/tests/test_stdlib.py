"""Built-in library edge cases (SPEC section 15), exercised through Vellum programs."""

import math

import pytest

from langvm import stdlib
from langvm.diagnostics import Panic
from langvm.floatfmt import show_float_at


@pytest.mark.parametrize(
    "x, d, expected",
    [
        (1.0, 6, "1.000000"),
        (0.1, 6, "0.100000"),
        (2.0 / 3.0, 6, "0.666667"),
        (-0.0, 6, "-0.000000"),
        (2.5, 0, "2"),
        (3.5, 0, "4"),
        (0.5, 0, "0"),
        (0.1 + 0.2, 17, "0.30000000000000004"),
        (1e21, 2, "1000000000000000000000.00"),
        (2.675, 2, "2.67"),
        (math.nan, 3, "nan"),
        (-math.nan, 3, "nan"),
        (math.inf, 3, "inf"),
        (-math.inf, 3, "-inf"),
        (-0.0000001, 6, "-0.000000"),
    ],
)
def test_show_float_at(x, d, expected):
    assert show_float_at(x, d) == expected


def test_float_rounding_functions_keep_signed_zero():
    assert math.copysign(1, stdlib.ceil_f(-0.5)) == -1
    assert math.copysign(1, stdlib.round_f(-0.4)) == -1
    assert stdlib.round_f(2.5) == 3.0 and stdlib.round_f(-2.5) == -3.0
    assert stdlib.round_f(0.49999999999999994) == 0.0
    assert stdlib.floor_f(-2.5) == -3.0 and stdlib.trunc_f(-2.9) == -2.0
    assert math.isnan(stdlib.floor_f(math.nan)) and stdlib.ceil_f(math.inf) == math.inf


def test_min_max_and_cmp_rank_nan_last():
    assert stdlib.cmp_f(math.nan, 1.0) == 1 and stdlib.cmp_f(1.0, math.nan) == -1
    assert stdlib.cmp_f(math.nan, math.nan) == 0
    assert stdlib.min_f(math.nan, 1.0) == 1.0 and math.isnan(stdlib.max_f(math.nan, 1.0))
    assert math.copysign(1, stdlib.min_f(-0.0, 0.0)) == -1
    assert math.copysign(1, stdlib.min_f(0.0, -0.0)) == 1


def test_fmod_pow_and_division_by_zero():
    assert math.isnan(stdlib.fmod_f(1.0, 0.0)) and math.isnan(stdlib.fmod_f(math.inf, 2.0))
    assert stdlib.fmod_f(5.0, math.inf) == 5.0 and stdlib.fmod_f(-7.5, 2.0) == -1.5
    assert stdlib.pow_f(2.0, 10) == 1024.0 and stdlib.pow_f(2.0, -2) == 0.25
    assert stdlib.pow_f(0.0, -1) == math.inf
    with pytest.raises(Panic):
        stdlib.pow_f(2.0, -(1 << 63))
    assert stdlib.fdiv(-1.0, 0.0) == -math.inf and math.isnan(stdlib.fdiv(0.0, 0.0))
    assert stdlib.fdiv(1.0, -0.0) == -math.inf


def test_integer_helpers():
    assert stdlib.abs_i(-(1 << 63)) == -(1 << 63)
    assert stdlib.div_floor(-7, 2) == -4 and stdlib.mod_floor(-7, 2) == 1
    assert stdlib.div_floor(-(1 << 63), -1) == -(1 << 63)
    assert stdlib.pow_i(3, 20) == 3486784401 and stdlib.pow_i(2, 64) == 0
    assert stdlib.gcd_i(-84, 36) == 12 and stdlib.gcd_i(0, 0) == 0
    assert (stdlib.pop_count(-1), stdlib.clz(1), stdlib.ctz(8), stdlib.clz(0), stdlib.ctz(0)) == (64, 63, 3, 64, 64)
    assert stdlib.show_int_radix(-255, 2) == "-11111111"
    assert stdlib.show_int_radix(-(1 << 63), 16) == "-8000000000000000"


def test_parse_int_and_radix():
    some = lambda v: (stdlib.SOME_UID, v)
    assert stdlib.parse_int("-0042") == some(-42) and stdlib.parse_int("+7") == some(7)
    for bad in ["", "-", " 1", "1_0", "0x1", "9223372036854775808", "٣"]:
        assert stdlib.parse_int(bad) == stdlib.NONE
    assert stdlib.parse_int("-9223372036854775808") == some(-(1 << 63))
    assert stdlib.parse_int_radix("Ff", 16) == some(255)
    assert stdlib.parse_int_radix("12", 2) == stdlib.NONE
    with pytest.raises(Panic):
        stdlib.parse_int_radix("1", 37)


def test_parse_float():
    some = lambda v: (stdlib.SOME_UID, v)
    assert stdlib.parse_float("12.") == some(12.0) and stdlib.parse_float(".5") == some(0.5)
    assert stdlib.parse_float("-1e3") == some(-1000.0)
    assert stdlib.parse_float("1e999") == some(math.inf)
    for bad in ["", ".", "e5", "1e", "inf", "nan", " 1", "1_0", "1.5.2"]:
        assert stdlib.parse_float(bad) == stdlib.NONE


def test_string_functions():
    assert stdlib.str_split("a,,b", ",") == ["a", "", "b"]
    assert stdlib.str_split("", ",") == [""]
    assert stdlib.str_split("aaa", "aa") == ["", "a"]
    assert stdlib.str_replace("aaa", "aa", "b") == "ba"
    assert stdlib.quote_str('a"b\n') == '"a\\"b\\n"'
    assert stdlib.quote_char("'") == "'\\''" and stdlib.quote_char("\x01") == "'\\u{1}'"
    assert stdlib.pad_left("7", 3, "0") == "007" and stdlib.pad_right("abcd", 2, "-") == "abcd"
    assert stdlib.fmt("{{{}}} {}%", ["x", "y"]) == "{x} y%"
    assert stdlib.substr("héllo", 1, 3) == "él"
    with pytest.raises(Panic):
        stdlib.substr("abc", 2, 1)
    with pytest.raises(Panic):
        stdlib.fmt("}", [])


def test_float_bits_round_trip():
    assert stdlib.float_bits(1.0) == 4607182418800017408
    assert stdlib.float_from_bits(4614256656552045848) == math.pi
    assert stdlib.float_bits(-0.0) == -(1 << 63)


def test_all_132_builtins_are_present_in_the_prelude():
    from langvm.prelude import BUILTIN_NAMES

    assert len(BUILTIN_NAMES) == 132 and BUILTIN_NAMES == sorted(set(BUILTIN_NAMES))


def test_list_and_map_library_through_vellum(run_main):
    body = """
    let xs = [3, 1, 2];
    print(strJoin(listMap(reverseList(xs), |v| showInt(v)), ""));
    print(showInt(listFold(xs, 0, |a, x| a + x)));
    print(showBool(listAny(xs, |x| x > 2)) ++ showBool(listAll(xs, |x| x > 2)));
    print(showInt(unwrapOr(listFind(xs, |x| x < 3), 0)) ++ showInt(listFindIndex(xs, |x| x == 2)));
    print(showInt(listIndexOf(xs, 2)) ++ showBool(listContains(xs, 9)));
    print(showInt(listLen(listZip(xs, ["a", "b"]))));
    print(showInt(listLen(listFlatten([[1], [2, 3], []]))));
    print(strJoin(listMap(slice(xs, 1, 3), |v| showInt(v)), ","));
    var ys = [1, 2, 3];
    insert(ys, 1, 9);
    removeAt(ys, 0);
    print(strJoin(listMap(ys, |v| showInt(v)), ","));
    var m: #[Str: Int] = mapNew();
    m["x"] = 1;
    print(showInt(mapGetOr(m, "y", 7)) ++ showBool(mapDel(m, "x")) ++ showBool(mapDel(m, "x")));
    print(showInt(listLen(pairsOf(#[1: 2, 3: 4]))));
    """
    assert run_main(body) == "213\n6\ntruefalse\n12\n2false\n2\n3\n1,2\n9,2,3\n7truefalse\n2\n"
