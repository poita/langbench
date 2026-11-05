#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `protowire` problem.

Every test is either an embedded literal or the product of a seeded
generator, so re-running this script reproduces the suite exactly. Expected
outputs come from reference/main.py. Every request is then cross-checked
against protoc + the protobuf runtime: the test's schema is turned into a
.proto file, compiled with `protoc --python_out`, and each `encode` result
is compared byte for byte with SerializeToString() while each `decode`
result is compared value for value with ParseFromString(). Any disagreement
aborts generation. The one deliberate exclusion: streams with a
field-number-0 tag inside a skipped group, which upb accepts but SPEC.md
(like the protobuf spec) rejects; the oracle check scans for and excludes
exactly those streams and reports how many it excluded.
"""
import importlib
import os
import random
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
REF = os.path.join(HERE, 'reference', 'main.py')
PROTOC = '/opt/homebrew/bin/protoc'
ORACLE_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".oracle-venv", "bin", "python")

SCALARS = ['int32', 'int64', 'uint32', 'uint64', 'sint32', 'sint64', 'bool',
           'fixed32', 'fixed64', 'sfixed32', 'sfixed64', 'string', 'bytes']
SIGNED = {'int32', 'int64', 'sint32', 'sint64', 'sfixed32', 'sfixed64'}
RANGE = {
    'int32': (-2 ** 31, 2 ** 31 - 1), 'sint32': (-2 ** 31, 2 ** 31 - 1), 'sfixed32': (-2 ** 31, 2 ** 31 - 1),
    'int64': (-2 ** 63, 2 ** 63 - 1), 'sint64': (-2 ** 63, 2 ** 63 - 1), 'sfixed64': (-2 ** 63, 2 ** 63 - 1),
    'uint32': (0, 2 ** 32 - 1), 'fixed32': (0, 2 ** 32 - 1),
    'uint64': (0, 2 ** 64 - 1), 'fixed64': (0, 2 ** 64 - 1),
}
WIRE = {'int32': 0, 'int64': 0, 'uint32': 0, 'uint64': 0, 'sint32': 0, 'sint64': 0, 'bool': 0,
        'fixed32': 5, 'sfixed32': 5, 'fixed64': 1, 'sfixed64': 1, 'string': 2, 'bytes': 2}

cases = []


def add(name, schema, requests):
    cases.append((name, schema.strip('\n') + '\n--\n' + '\n'.join(requests) + '\n'))


# ---------------------------------------------------------------------------
# Small wire-format writer used to craft decode payloads (unknown fields,
# unpacked repeated values, non-minimal varints, groups).
# ---------------------------------------------------------------------------
def varint(v, min_bytes=1):
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v or len(out) + 1 < min_bytes:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def tag(number, wire):
    return varint((number << 3) | wire)


def zz(v, bits):
    return ((v << 1) ^ (v >> (bits - 1))) & ((1 << bits) - 1)


def scalar_bytes(t, v):
    """Wire bytes of one scalar value without its tag."""
    if t in ('int32', 'int64'):
        return varint(v & (2 ** 64 - 1))
    if t in ('uint32', 'uint64'):
        return varint(v)
    if t == 'sint32':
        return varint(zz(v, 32))
    if t == 'sint64':
        return varint(zz(v, 64))
    if t == 'bool':
        return varint(1 if v else 0)
    if t in ('fixed32', 'sfixed32'):
        return (v & 0xFFFFFFFF).to_bytes(4, 'little')
    if t in ('fixed64', 'sfixed64'):
        return (v & (2 ** 64 - 1)).to_bytes(8, 'little')
    if t == 'string':
        raw = v.encode('utf-8')
        return varint(len(raw)) + raw
    if t == 'bytes':
        return varint(len(v)) + v
    raise AssertionError(t)


def ld(number, payload):
    return tag(number, 2) + varint(len(payload)) + payload


def dec(name, data):
    """A decode request line; an empty payload leaves nothing (not even a space) after the name."""
    return 'decode %s %s' % (name, data.hex()) if data else 'decode %s' % name


# ---------------------------------------------------------------------------
# Canonical text rendering of Python values. A message is a tuple of
# (field name, value) pairs; a repeated field is a list.
# ---------------------------------------------------------------------------
def render_str(s):
    out = ['"']
    for ch in s:
        c = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == '\\':
            out.append('\\\\')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\r':
            out.append('\\r')
        elif ch == '\t':
            out.append('\\t')
        elif c < 0x20 or c == 0x7F:
            out.append('\\x%02x' % c)
        else:
            out.append(ch)
    out.append('"')
    return ''.join(out)


def render(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return render_str(v)
    if isinstance(v, bytes):
        return 'x"' + v.hex() + '"'
    if isinstance(v, list):
        return '[' + ', '.join(render(x) for x in v) + ']'
    assert isinstance(v, tuple)
    return '{' + ', '.join(k + ': ' + render(x) for k, x in v) + '}'


# ---------------------------------------------------------------------------
# Hand-written tests
# ---------------------------------------------------------------------------
add('spec_example_1', '''
message Inner { sint32 v = 1; }
message Outer {
  int32 a = 1;
  string b = 2;
  repeated int32 c = 3;
  Inner d = 4;
}
''', [
    'encode Outer {a: 1, b: "x", c: [1, 2], d: {v: -5}}',
    'decode Outer 08011201781a02010222020809',
    'encode Outer {d: {}, c: [], a: 0}',
    'decode Outer 3800',
    'decode Outer 08ff',
])

add('spec_example_2', '''
message M { uint64 u = 1; sint64 s = 2; fixed32 f = 3; bytes y = 4; repeated bool bs = 5; bool k = 6; }
''', [
    'decode M 08ffffffffffffffffff0110ff011dffffffff2202000f2a03010001',
    'decode M 3002',
    'decode M 3d000000',
    'encode M {k: true, y: x"cafe", s: -128, u: 18446744073709551615}',
    'encode M {u: -1}',
])

add('spec_example_3', '''
message P { repeated int32 r = 1; P p = 2; string s = 3; }
''', [
    'decode P 0801080212020803120208041a0322095c',
    'decode P 1b08011c0805',
    'decode P 1b08011400',
])

add('empty_messages', '''
message E {}
message W { E e = 1; repeated E es = 2; int32 n = 3; }
''', [
    'decode E',
    'encode E {}',
    'decode W',
    'encode W {}',
    'encode W {e: {}}',
    'decode W 0a00',
    'encode W {es: [{}, {}, {}]}',
    'decode W 120012001200',
    'encode W {es: []}',
    'encode W {n: 0, e: {}, es: []}',
    'decode W 0a001800',
])

add('int32_int64', '''
message I { int32 a = 1; int64 b = 2; repeated int32 ra = 3; repeated int64 rb = 4; }
''', [
    'encode I {a: 1}',
    'encode I {a: -1}',
    'encode I {a: 127, b: 128}',
    'encode I {a: 2147483647, b: 9223372036854775807}',
    'encode I {a: -2147483648, b: -9223372036854775808}',
    'encode I {b: -1}',
    'encode I {ra: [0, -1, 300, -2147483648], rb: [-9223372036854775808, 1]}',
    'decode I 08ffffffffffffffffff01',
    'decode I 08ffffffff07',
    'decode I 088080808008',
    'decode I 08ffffffff0f',
    'decode I 088080808010',
    'decode I 0880808080808080808001',
    'decode I 10ffffffffffffffff7f',
    'decode I 10ffffffffffffffffff01',
    'decode I 1080808080808080808001',
    'decode I 1a0a00ffffffffffffffffff01',
    'encode I {a: 2147483648}',
    'encode I {a: -2147483649}',
    'encode I {b: 9223372036854775808}',
    'encode I {b: -9223372036854775809}',
])

add('uint32_uint64', '''
message U { uint32 a = 1; uint64 b = 2; repeated uint64 rb = 3; }
''', [
    'encode U {a: 4294967295}',
    'encode U {b: 18446744073709551615}',
    'encode U {a: 300, b: 4294967296}',
    'encode U {rb: [0, 1, 128, 16384, 2097152, 268435456, 34359738368, 4398046511104, 562949953421312, 72057594037927936, 9223372036854775808, 18446744073709551615]}',
    'decode U 08ffffffff0f',
    'decode U 08ffffffffff01',
    'decode U 10ffffffffffffffffff01',
    'decode U 10ffffffffffffffffff7f',
    'decode U 08ffffffffffffffffff01',
    'encode U {a: 4294967296}',
    'encode U {b: 18446744073709551616}',
    'encode U {a: -1}',
    'encode U {b: -0}',
])

add('sint32_sint64', '''
message S { sint32 a = 1; sint64 b = 2; repeated sint32 ra = 3; repeated sint64 rb = 4; }
''', [
    'encode S {a: -1}',
    'encode S {a: 1}',
    'encode S {a: -2, b: 2}',
    'encode S {a: 2147483647, b: 9223372036854775807}',
    'encode S {a: -2147483648, b: -9223372036854775808}',
    'encode S {ra: [0, -1, 1, -64, 64, -65], rb: [-1, -4611686018427387904, 4611686018427387904]}',
    'decode S 0801',
    'decode S 0802',
    'decode S 08ffffffff0f',
    'decode S 08feffffff0f',
    'decode S 088180808010',
    'decode S 08ffffffffffffffffff01',
    'decode S 10ffffffffffffffffff01',
    'decode S 10feffffffffffffffff01',
    'decode S 1a03010203',
    'encode S {a: 2147483648}',
    'encode S {b: -9223372036854775809}',
])

add('bool_values', '''
message B { bool a = 1; bool b = 2; repeated bool r = 3; }
''', [
    'encode B {a: true}',
    'encode B {b: true, a: false}',
    'encode B {r: [true, false, false, true]}',
    'encode B {r: [false]}',
    'decode B 0801',
    'decode B 0800',
    'decode B 0802',
    'decode B 08ffffffffffffffffff01',
    'decode B 1a04010200ff',
    'decode B 180118001805',
    'decode B 1a00',
    'encode B {a: 1}',
    'encode B {a: True}',
    'encode B {a: "true"}',
])

add('fixed_types', '''
message F { fixed32 a = 1; fixed64 b = 2; sfixed32 c = 3; sfixed64 d = 4;
  repeated fixed32 ra = 5; repeated fixed64 rb = 6; repeated sfixed32 rc = 7; repeated sfixed64 rd = 8; }
''', [
    'encode F {a: 1, b: 1, c: 1, d: 1}',
    'encode F {a: 4294967295, b: 18446744073709551615, c: -1, d: -1}',
    'encode F {c: -2147483648, d: -9223372036854775808}',
    'encode F {a: 305419896, b: 1311768467463790320}',
    'encode F {ra: [0, 1], rb: [0], rc: [-1, 2147483647], rd: [-2, 9223372036854775807]}',
    'decode F 0d78563412',
    'decode F 11f0debc9a78563412',
    'decode F 1dffffffff',
    'decode F 21ffffffffffffffff',
    'decode F 2a0801000000ffffffff',
    'decode F 32100100000000000000ffffffffffffffff',
    'decode F 3d010000003dffffffff',
    'decode F 4102000000000000004100000000000000ff',
    'decode F 0d010000',
    'decode F 1101000000000000',
    'encode F {a: -1}',
    'encode F {c: 2147483648}',
    'encode F {b: 18446744073709551616}',
])

add('string_values', '''
message T { string s = 1; repeated string rs = 2; }
''', [
    'encode T {s: "hello"}',
    'encode T {s: ""}',
    'encode T {s: "a b  c"}',
    'encode T {s: "quote\\" backslash\\\\ nl\\n cr\\r tab\\t"}',
    'encode T {s: "\\x00\\x01\\x1f\\x7f"}',
    'encode T {s: "\\x41\\X42\\xc3\\xa9\\xf0\\x9f\\x98\\x80"}',
    'encode T {s: "héllo wörld 日本語 😀"}',
    'encode T {s: "a\x7fb"}',
    'encode T {rs: ["", "a", "", "b"]}',
    'encode T {s: "\\xff"}',
    'encode T {s: "\\xc0\\xaf"}',
    'encode T {s: "\\xed\\xa0\\x80"}',
    'encode T {s: "\\xf4\\x90\\x80\\x80"}',
    'encode T {s: "\\q"}',
    'encode T {s: "\\x4"}',
    'encode T {s: "\\x4g"}',
    'encode T {s: "unterminated}',
    'encode T {s: "a"b"}',
    'decode T 0a0568656c6c6f',
    'decode T 0a00',
    'decode T 0a0722095c0d0a017f',
    'decode T 0a0e68c3a96c6c6f20e697a5f09f9880',
    'decode T 0a0100',
    'decode T 0a01ff',
    'decode T 0a02c0af',
    'decode T 0a03eda080',
    'decode T 0a04f4908080',
    'decode T 0a02c3',
    'decode T 0a03e282',
    'decode T 0a0480808080',
    'decode T 1200120161120012025c22',
    'decode T 120161120102ff',
])

add('bytes_values', '''
message Y { bytes y = 1; repeated bytes ry = 2; string s = 3; }
''', [
    'encode Y {y: x"00"}',
    'encode Y {y: x""}',
    'encode Y {y: x"ff00fe01"}',
    'encode Y {ry: [x"", x"ab", x"", x"c0af"]}',
    'encode Y {y: x"AB"}',
    'encode Y {y: x"abc"}',
    'encode Y {y: "ab"}',
    'encode Y {y: x"ab" }',
    'encode Y {y: x "ab"}',
    'decode Y 0a01ff',
    'decode Y 0a04c0afeda0',
    'decode Y 0a00',
    'decode Y 12001201ff1200',
    'decode Y 0a03000102',
])

add('nested_messages', '''
message Top { Mid m = 1; repeated Mid ms = 2; int32 n = 3; }
message Mid { Leaf l = 1; string name = 2; repeated Leaf ls = 3; }
message Leaf { int32 v = 1; bool b = 2; }
''', [
    'encode Top {m: {l: {v: 1}}}',
    'encode Top {m: {l: {}}}',
    'encode Top {m: {l: {v: 0, b: false}}}',
    'encode Top {m: {}, n: 7}',
    'encode Top {ms: [{name: "a"}, {}, {l: {b: true}, ls: [{}, {v: -1}]}], n: 1}',
    'decode Top 0a040a020801',
    'decode Top 0a020a00',
    'decode Top 0a00',
    'decode Top 1200120312016112001800',
    'decode Top 0a0a1a0008011a020801120018010a021202ab',
    'decode Top 0a0212a0',
    'decode Top 0a030a0108',
    'encode Top {m: {l: 5}}',
    'encode Top {m: [{}]}',
    'encode Top {ms: {}}',
    'encode Top {n: {}}',
])

add('recursive_message', '''
message Node { int32 v = 1; Node next = 2; repeated Node kids = 3; }
''', [
    'encode Node {v: 1, next: {v: 2, next: {v: 3, next: {}}}}',
    'encode Node {kids: [{kids: [{kids: [{v: 9}]}]}]}',
    'decode Node 080112061202120208ff01',
    'decode Node ' + ''.join(['12%02x' % (2 * (31 - i) + 2) for i in range(32)]) + '0801',
    'encode Node ' + '{next: ' * 63 + '{v: 1}' + '}' * 63,
])

add('repeated_packed_decode', '''
message R { repeated int32 a = 1; repeated int64 b = 2; repeated uint32 c = 3; repeated uint64 d = 4;
  repeated sint32 e = 5; repeated sint64 f = 6; repeated bool g = 7; repeated fixed32 h = 8;
  repeated fixed64 i = 9; repeated sfixed32 j = 10; repeated sfixed64 k = 11; }
''', [
    'decode R 0a03010203',
    'decode R 0a0bffffffffffffffffff0100',
    'decode R 120bffffffffffffffffff0101',
    'decode R 1a05ffffffff0f',
    'decode R 220affffffffffffffffff01',
    'decode R 2a04010203ff01',
    'decode R 320bffffffffffffffffff0101',
    'decode R 3a0400010200',
    'decode R 42080100000002000000',
    'decode R 4a1001000000000000000200000000000000',
    'decode R 5208ffffffff00000080',
    'decode R 5a10ffffffffffffffff0000000000000080',
    'decode R 0a0201020a0003040a0105',
    'decode R 0a00',
    'decode R 4200',
    'decode R 0a0281',
    'decode R 0a0bffffffffffffffffffff01',
    'decode R 4203010000',
    'decode R 42050100000002',
    'decode R 4a07010000000000',
    'decode R 5205ffffffff00',
    'decode R 5a09ffffffffffffffff00',
    'decode R 0a',
    'decode R 0a05010203',
])

add('repeated_unpacked_decode', '''
message R { repeated int32 a = 1; repeated sint64 b = 2; repeated bool c = 3; repeated fixed32 d = 4;
  repeated sfixed64 e = 5; repeated string s = 6; }
''', [
    'decode R 080108020803',
    'decode R 08010a02020308040a00',
    'decode R 10011003',
    'decode R 18011800187f',
    'decode R 25010000002500000080',
    'decode R 29ffffffffffffffff',
    'decode R 320161320162',
    'decode R 3200',
    'decode R 08ffffffffffffffffff0108ffffffff0f',
    'decode R 0801080208',
    'decode R 250100',
    'decode R 3201',
    'decode R 3202616232',
])

add('repeated_encode', '''
message R { repeated int32 a = 1; repeated sint32 b = 2; repeated fixed64 c = 3; repeated string s = 4;
  repeated bytes y = 5; repeated bool g = 6; repeated uint64 u = 7; repeated sfixed32 j = 8; }
''', [
    'encode R {a: [0]}',
    'encode R {a: [0, 0, 0]}',
    'encode R {a: []}',
    'encode R {a: [1], b: [-1], c: [1], s: ["x"], y: [x"ff"], g: [true], u: [1], j: [-1]}',
    'encode R {s: ["", ""]}',
    'encode R {y: [x""]}',
    'encode R {g: [false]}',
    'encode R {u: [18446744073709551615, 0]}',
    'encode R {a: [-1, 2147483647, -2147483648]}',
    'encode R {a: 1}',
    'encode R {a: [1, [2]]}',
    'encode R {a: [1,]}',
    'encode R {a: [,1]}',
    'encode R {a: [1 2]}',
    'encode R {a: [1, "2"]}',
    'encode R {s: ["a", 1]}',
    'encode R {a: [4294967295]}',
])

add('unknown_fields', '''
message K { int32 a = 1; string s = 2; }
''', [
    'decode K 1805',
    'decode K 18ffffffffffffffffff01',
    'decode K 190102030405060708',
    'decode K 1a03ff0f0e',
    'decode K 1a00',
    'decode K 1d01020304',
    'decode K 1b1c',
    'decode K 1b08051a02ffff1c',
    'decode K 1b231b1c241c',
    'decode K 1b0f1c',
    'decode K 1b001c',
    'decode K 1b1b1c',
    'decode K 1c',
    'decode K 1b08051a',
    'decode K 1b08051c0801',
    'decode K 08011805120178',
    'decode K f8ffffff0f01',
    'decode K f8ffffff0f00',
    'decode K 8080808008ff01',
    'decode K 1805080a',
    'decode K ' + 'ab010801ac01' * 8 + '0801',
    'decode K 1a80808080000801',
    'decode K 1a8080808080000801',
    'decode K 1b1a80808080001c0801',
    'decode K 1b1a8080808080001c0801',
    'decode K 1bf8ffffff0f001c0801',
    'decode K 1bf8ffffff1f001c0801',
    'decode K 1b8080808010001c0801',
    'decode K 1b80808080800100001c0801',
    'decode K 1b18ffffffffffffffffff011c0801',
    'decode K 1b188080808080808080808001' + '1c0801',
    'decode K 1b1a03ffffff1c0801',
    'decode K ' + '1b' * 64 + '1c' * 64,
])

add('wire_type_mismatch', '''
message W { int32 a = 1; string s = 2; fixed32 f = 3; repeated int32 r = 4; repeated string rs = 5; W w = 6; repeated fixed64 rf = 7; }
''', [
    'decode W 0a0105',
    'decode W 0a0105080a',
    'decode W 1005',
    'decode W 1801',
    'decode W 1d00000000',
    'decode W 2501000000',
    'decode W 2801',
    'decode W 3005',
    'decode W 3d00000000',
    'decode W 0d0102030408011a0161',
    'decode W 0b0c0801',
    'decode W 3901000000000000003a0801000000000000003d01000000',
    'decode W 0a',
    'decode W 0d0102',
])

add('merge_and_last_wins', '''
message M { int32 a = 1; string s = 2; Sub m = 3; repeated int32 r = 4; }
message Sub { int32 x = 1; repeated int32 y = 2; Sub deep = 3; string t = 4; }
''', [
    'decode M 080108020803',
    'decode M 120161120162',
    'decode M 1a0208011a020802',
    'decode M 1a04100110021a02100310041a0210051a0210061a00',
    'decode M 1a0408011a001a0208021a0022020803',
    'decode M 1a041a0208011a041a021002',
    'decode M 1a0222016122001a0222016222001a02220163',
    'decode M 1a00',
    'decode M 1a0208011a021000',
    'decode M 1a0308011a1a0022',
    'decode M 20012002200320001a020801',
    'decode M 1a020801080520011a02100112016120012a00',
])

add('varint_and_tag_edges', '''
message V { uint64 u = 1; int32 i = 2; sint32 s = 3; bool b = 4; int32 big = 536870911; string t = 5; }
''', [
    'decode V 0881808080808080808000',
    'decode V 088000',
    'decode V 0880808080808080808000',
    'decode V 0880808080808080808002',
    'decode V 08ffffffffffffffffff7f',
    'decode V 08ffffffffffffffffff02',
    'decode V 088080808080808080808001',
    'decode V 08ffffffffffffffffff80',
    'decode V 108180808010',
    'decode V 18ffffffffffffffffff01',
    'decode V 1880808080808080808001',
    'decode V 2080808080808080808002',
    'decode V 208080808080808080800a',
    'decode V 8800000005',
    'decode V 8880808000',
    'decode V 888080808000',
    'decode V f8ffffff0f07',
    'decode V f8ffffff1f07',
    'decode V f8ffffffff0107',
    'decode V ffffffff0f',
    'decode V 00',
    'decode V 0005',
    'decode V 0e',
    'decode V 0f',
    'decode V 07',
    'decode V 06',
    'decode V 2a810061',
    'decode V 2a818080800062',
    'decode V 2a81808080800063',
    'decode V 2aff01',
    'decode V 2affffffff0f',
    'decode V 2affffffffffffffffff01',
    'decode V 2a80808080808080808000',
    'decode V 2a00',
    'encode V {big: 1}',
    'encode V {big: 1, u: 1}',
])

add('malformed_streams', '''
message X { int32 a = 1; string s = 2; fixed32 f = 3; fixed64 g = 4; X x = 5; repeated int32 r = 6; }
''', [
    'decode X 08',
    'decode X 0880',
    'decode X 08ffff',
    'decode X 12',
    'decode X 1205',
    'decode X 120561',
    'decode X 1201',
    'decode X 12ffffffff0f',
    'decode X 1d',
    'decode X 1d0102',
    'decode X 1d010203',
    'decode X 21',
    'decode X 2101020304050607',
    'decode X 2a',
    'decode X 2a01',
    'decode X 2a0108',
    'decode X 2a021205',
    'decode X 2a032a0108',
    'decode X 3201',
    'decode X 3202018',
    'decode X 32ff',
    'decode X 0801120178ff',
    'decode X 0801f',
    'decode X 08011',
    'decode X zz',
    'decode X 0G',
    'decode X 0801 ',
    'decode X',
    'decode X ',
    'decode X 08 01',
    'decode X 0801 1201',
    'decode X ' + 'ff' * 12,
    'decode X 0801' + 'f8ffffffff' + '01',
])

add('encode_text_errors', '''
message E { int32 a = 1; string s = 2; bool b = 3; Sub m = 4; repeated int32 r = 5; uint32 u = 6; bytes y = 7; }
message Sub { int32 v = 1; }
''', [
    'encode E {a: 1, a: 2}',
    'encode E {a: 1, z: 2}',
    'encode E {A: 1}',
    'encode E {a: 1,}',
    'encode E {,a: 1}',
    'encode E {a: 1,, s: "x"}',
    'encode E {a 1}',
    'encode E {a: }',
    'encode E {a: 1',
    'encode E a: 1}',
    'encode E {a: 1}}',
    'encode E {a: 1} x',
    'encode E {}{}',
    'encode E {a: +1}',
    'encode E {a: 01}',
    'encode E {a: 007}',
    'encode E {a: -0}',
    'encode E {a: 1.0}',
    'encode E {a: 1e3}',
    'encode E {a: 0x10}',
    'encode E {a: - 1}',
    'encode E {a: --1}',
    'encode E {a: "1"}',
    'encode E {a: true}',
    'encode E {a: {}}',
    'encode E {a: []}',
    'encode E {s: 1}',
    'encode E {s: x"00"}',
    'encode E {s: {}}',
    'encode E {b: 0}',
    'encode E {b: false, b: true}',
    'encode E {b: TRUE}',
    'encode E {b: truee}',
    'encode E {b: tru}',
    'encode E {m: {v: 1, v: 2}}',
    'encode E {m: {w: 1}}',
    'encode E {m: {v: 1}, m: {v: 2}}',
    'encode E {m: {v: 1}}}',
    'encode E {m: {v: 1}',
    'encode E {m: null}',
    'encode E {r: [1, 2], r: [3]}',
    'encode E {r: [1, 2]]}',
    'encode E {r: [[1]]}',
    'encode E {u: 4294967296}',
    'encode E {u: -1}',
    'encode E {y: x"0"}',
    'encode E {y: x"gg"}',
    'encode E {y: x""}',
    'encode E {y: "00"}',
    'encode E {y: x\'00\'}',
    'encode E {\'a\': 1}',
    'encode E {"a": 1}',
    'encode E {a: 1; s: "x"}',
    'encode E {a:1;}',
    'encode E {a = 1}',
    'encode E {a: 1\t}',
    'encode E {a:\t1}',
    'encode E {a: 1, s: "x\ty"}',
    'encode E',
    'encode E ',
    'encode E {',
    'encode E }',
    'encode E []',
    'encode E [{a: 1}]',
    'encode E 5',
    'encode E {a: 1} {a: 2}',
    'encode E { }',
    'encode E {a :1}',
])

add('encode_text_relaxed', '''
message E { int32 a = 1; string s = 2; bool b = 3; Sub m = 4; repeated int32 r = 5; uint32 u = 6; bytes y = 7; repeated Sub ms = 8; }
message Sub { int32 v = 1; repeated string t = 2; }
''', [
    'encode E {a:1}',
    'encode E {a:1,s:"x",b:true,m:{v:2},r:[1,2,3],u:4,y:x"05",ms:[{},{v:1,t:["a","b"]}]}',
    'encode E {  a  :  1  ,  s  :  "x"  ,  r  :  [  1  ,  2  ]  ,  m  :  {  v  :  2  }  }',
    'encode E {ms: [{v: 1}], y: x"05", u: 4, r: [1, 2, 3], m: {v: 2}, b: true, s: "x", a: 1}',
    'encode E {a: 0, s: "", b: false, r: [], u: 0, y: x""}',
    'encode E {u: 0, a: 5, m: {v: 0, t: []}, s: ""}',
    'encode E {s: "spaces   inside , and : and } and ] and \\" too"}',
    'encode E {s: "{}[],:"}',
    'encode E {ms: [{t: ["x y", "z"]}, {}]}',
    'encode E {r: [1,2,3]}',
    'encode E {r: [ 1 ]}',
    'encode E {r:[]}',
    'encode E {m:{}}',
    'encode E {m: { }}',
    'encode E {y: x"0a0b"}',
    'encode E {s: "\\x7e\\x7f\\x20"}',
    'encode E {s: "\\xF0\\x9F\\x98\\x80"}',
    'encode E   {a: 1}',
    'encode E {a: 1}  ',
])

add('schema_formatting', '''
message A{int32 x=1;repeated B ys=3;string name=2;}
message B{sint64 v=2;A back=1;}
message Unused { int32 q = 1; }
''', [
    'encode A {x: 1, ys: [{v: -1, back: {name: "n"}}], name: "a"}',
    'decode A 08011202611a0808011002120161',
    'encode B {back: {ys: [{back: {ys: [{}]}}]}}',
    'encode Unused {q: 1}',
])

add('field_numbers_scrambled', '''
message Z {
  string j = 10;
  int32 a = 1;
  repeated int32 r = 536870911;
  bool b = 200;
  Z z = 3;
  bytes y = 18999;
  fixed32 f = 20000;
  int64 g = 2;
}
''', [
    'encode Z {j: "j", a: 1, r: [1], b: true, z: {}, y: x"aa", f: 1, g: 2}',
    'encode Z {r: [2], j: "k", a: 0}',
    'decode Z ' + (tag(1, 0) + varint(1) + tag(2, 0) + varint(2) + ld(10, b'j') + tag(200, 0) + varint(1)
                   + ld(18999, b'\xaa') + tag(20000, 5) + b'\x01\0\0\0' + ld(3, b'') + ld(536870911, b'\x01')).hex(),
    'decode Z ' + (ld(536870911, b'\x02') + ld(3, ld(3, b''))).hex(),
    'decode Z ' + (tag(536870911, 0) + varint(1)).hex(),
    'decode Z ' + varint((536870911 << 3) | 7).hex(),
])


# ---------------------------------------------------------------------------
# Generated tests
# ---------------------------------------------------------------------------
NAME_WORDS = ['id', 'name', 'value', 'count', 'flag', 'data', 'tags', 'items', 'child', 'parent',
              'total', 'ratio', 'key', 'label', 'size', 'left', 'right', 'body', 'head', 'tail',
              'x', 'y', 'z', 'w', 'n', 'k', 'v', 'a', 'b', 'c', 'note', 'extra', 'payload', 'seq']


def rand_schema(rng, n_messages, fields_per_message, allow_repeated=True, allow_messages=True):
    """Returns (schema_text, messages) where messages maps name -> list of (name, type, number, repeated)."""
    names = ['M%d' % i for i in range(n_messages)]
    rng.shuffle(names)
    messages = {}
    for mname in names:
        nfields = rng.randint(0, fields_per_message)
        used_names = set()
        used_numbers = set()
        fields = []
        for _ in range(nfields):
            while True:
                fname = rng.choice(NAME_WORDS) + (str(rng.randint(0, 99)) if rng.random() < 0.5 else '')
                if fname not in used_names:
                    break
            used_names.add(fname)
            while True:
                r = rng.random()
                if r < 0.7:
                    num = rng.randint(1, 15)
                elif r < 0.9:
                    num = rng.randint(16, 2047)
                else:
                    num = rng.choice([2048, 65535, 100000, 18999, 20000, 1 << 20, 536870911])
                if num not in used_numbers:
                    break
            used_numbers.add(num)
            if allow_messages and rng.random() < 0.2:
                t = rng.choice(names)
            else:
                t = rng.choice(SCALARS)
            repeated = allow_repeated and rng.random() < 0.3
            fields.append((fname, t, num, repeated))
        messages[mname] = fields
    lines = []
    for mname in names:
        if rng.random() < 0.3:
            lines.append('message %s { %s }' % (mname, ' '.join(
                '%s%s %s = %d;' % ('repeated ' if rep else '', t, f, n) for f, t, n, rep in messages[mname])))
        else:
            lines.append('message %s {' % mname)
            for f, t, n, rep in messages[mname]:
                lines.append('  %s%s %s = %d;' % ('repeated ' if rep else '', t, f, n))
            lines.append('}')
    return '\n'.join(lines), messages


def rand_scalar(rng, t):
    r = rng.random()
    if t == 'bool':
        return rng.random() < 0.6
    if t == 'string':
        n = rng.randint(0, 12)
        pool = 'abcdefghijklmnopqrstuvwxyz ABC0123 ,:{}[]"\\\n\t\r\x00\x01\x7féü日😀'
        return ''.join(rng.choice(pool) for _ in range(n))
    if t == 'bytes':
        return bytes(rng.randint(0, 255) for _ in range(rng.randint(0, 10)))
    lo, hi = RANGE[t]
    if r < 0.15:
        return 0
    if r < 0.3:
        return rng.choice([lo, hi, 1, -1 if lo < 0 else 1, 127, 128, 255, 256, 16383, 16384])
    if r < 0.6:
        return rng.randint(-100, 100) if lo < 0 else rng.randint(0, 200)
    return rng.randint(lo, hi)


def rand_value(rng, messages, mname, depth, density=0.6):
    """Random message value: a tuple of (field, value) pairs in schema order."""
    pairs = []
    for fname, t, num, rep in messages[mname]:
        if rng.random() > density:
            continue
        if t in SCALARS:
            if rep:
                pairs.append((fname, [rand_scalar(rng, t) for _ in range(rng.randint(0, 6))]))
            else:
                pairs.append((fname, rand_scalar(rng, t)))
        elif depth < 3:
            if rep:
                pairs.append((fname, [rand_value(rng, messages, t, depth + 1) for _ in range(rng.randint(0, 2))]))
            else:
                pairs.append((fname, rand_value(rng, messages, t, depth + 1)))
    return tuple(pairs)


def encode_value(rng, messages, mname, pairs, noise=0.0, unpacked=0.0, nonminimal=0.0):
    """Wire bytes of a message value, optionally with unknown fields, unpacked repeats
    and non-minimal varints mixed in; the value it decodes to is unchanged."""
    fields = {f: (t, n, rep) for f, t, n, rep in messages[mname]}
    used = {n for _, _, n, _ in messages[mname]}
    out = bytearray()

    def maybe_noise():
        if rng.random() < noise:
            while True:
                n = rng.randint(1, 300)
                if n not in used:
                    break
            kind = rng.random()
            if kind < 0.3:
                out.extend(tag(n, 0) + varint(rng.randint(0, 2 ** 64 - 1)))
            elif kind < 0.5:
                out.extend(tag(n, 1) + bytes(rng.randint(0, 255) for _ in range(8)))
            elif kind < 0.7:
                out.extend(tag(n, 5) + bytes(rng.randint(0, 255) for _ in range(4)))
            elif kind < 0.9:
                out.extend(ld(n, bytes(rng.randint(0, 255) for _ in range(rng.randint(0, 6)))))
            else:
                out.extend(tag(n, 3) + tag(1, 0) + varint(5) + ld(2, b'\xff') + tag(n, 4))

    def emit_tag(n, w):
        out.extend(varint((n << 3) | w, rng.choice([1, 2, 5]) if rng.random() < nonminimal else 1))

    order = list(pairs)
    if rng.random() < 0.3:
        rng.shuffle(order)
    for fname, v in order:
        maybe_noise()
        t, n, rep = fields[fname]
        if t in SCALARS:
            if rep:
                if not v:
                    continue
                if WIRE[t] == 2:
                    for item in v:
                        emit_tag(n, 2)
                        out.extend(scalar_bytes(t, item))
                elif rng.random() < unpacked:
                    for item in v:
                        emit_tag(n, WIRE[t])
                        out.extend(scalar_bytes(t, item))
                else:
                    payload = b''.join(scalar_bytes(t, item) for item in v)
                    emit_tag(n, 2)
                    out.extend(varint(len(payload)))
                    out.extend(payload)
            else:
                emit_tag(n, WIRE[t])
                if WIRE[t] == 0 and rng.random() < nonminimal:
                    out.extend(varint(_varint_value(t, v), rng.choice([2, 3, 10])))
                else:
                    out.extend(scalar_bytes(t, v))
        else:
            for item in (v if rep else [v]):
                sub = encode_value(rng, messages, t, item, noise, unpacked, nonminimal)
                emit_tag(n, 2)
                out.extend(varint(len(sub)))
                out.extend(sub)
    maybe_noise()
    return bytes(out)


def _varint_value(t, v):
    if t in ('int32', 'int64'):
        return v & (2 ** 64 - 1)
    if t == 'sint32':
        return zz(v, 32)
    if t == 'sint64':
        return zz(v, 64)
    if t == 'bool':
        return 1 if v else 0
    return v


def gen_random_case(seed, n_messages, fields_per_message, n_requests, noise=0.0, unpacked=0.0, nonminimal=0.0):
    rng = random.Random(seed)
    schema, messages = rand_schema(rng, n_messages, fields_per_message)
    reqs = []
    names = sorted(messages)
    for _ in range(n_requests):
        mname = rng.choice(names)
        pairs = rand_value(rng, messages, mname, 0)
        if rng.random() < 0.5:
            reqs.append('encode %s %s' % (mname, render(pairs)))
        else:
            data = encode_value(rng, messages, mname, pairs, noise, unpacked, nonminimal)
            reqs.append(dec(mname, data))
    return schema, reqs


add('random_small', *gen_random_case(101, 3, 6, 40))
add('random_medium', *gen_random_case(102, 6, 10, 200))
add('random_noisy', *gen_random_case(103, 5, 8, 200, noise=0.4, unpacked=0.5, nonminimal=0.3))
add('random_wide_schema', *gen_random_case(104, 12, 40, 150, noise=0.1, unpacked=0.3))

FUZZ_SCHEMA = '''
message Z { int32 a = 1; string s = 2; fixed32 f = 3; fixed64 g = 4; Z z = 5; repeated int32 r = 6;
  repeated sint64 q = 7; repeated fixed32 h = 8; bool b = 9; bytes y = 10; repeated string t = 11;
  repeated Z zs = 12; uint64 u = 13; sfixed64 k = 14; repeated bool bb = 15; }
'''


def gen_fuzz(seed, count):
    rng = random.Random(seed)
    reqs = []
    # Byte pool biased towards small tags of Z so streams often decode.
    tags = [tag(n, w) for n in range(1, 17) for w in (0, 1, 2, 3, 4, 5)]
    for _ in range(count):
        n = rng.randint(0, 24)
        out = bytearray()
        while len(out) < n:
            r = rng.random()
            if r < 0.5:
                out.extend(rng.choice(tags))
            elif r < 0.8:
                out.append(rng.randint(0, 255))
            else:
                out.append(rng.randint(0, 20))
        reqs.append(dec('Z', bytes(out[:n])))
    return reqs


add('fuzz_random_bytes', FUZZ_SCHEMA, gen_fuzz(201, 3000))


def gen_fuzz_text(seed, count):
    """Random mutations of valid encode texts: most are errors, some remain valid."""
    rng = random.Random(seed)
    schema, messages = rand_schema(rng, 3, 8)
    reqs = []
    names = sorted(messages)
    for _ in range(count):
        mname = rng.choice(names)
        text = render(rand_value(rng, messages, mname, 0, density=0.8))
        k = rng.randint(0, 3)
        for _ in range(k):
            pos = rng.randint(0, len(text) - 1) if text else 0
            op = rng.random()
            if op < 0.4:
                text = text[:pos] + text[pos + 1:]
            elif op < 0.8:
                text = text[:pos] + rng.choice('{}[],:"x0-19 abt\\') + text[pos:]
            else:
                text = text[:pos] + rng.choice(['true', '-1', '99999999999999999999', '""', 'x""', '{}', '[]', ', ', ' ']) + text[pos:]
        reqs.append('encode %s %s' % (mname, text))
    return schema, reqs


add('fuzz_text_mutations', *gen_fuzz_text(202, 2500))


def gen_big_repeated(seed, count, full=True):
    rng = random.Random(seed)
    schema = 'message Big { repeated int32 xs = 1; repeated string ss = 2; repeated sint64 qs = 3; repeated fixed32 fs = 4; repeated Big kids = 5; int32 n = 6; }'
    messages = {'Big': [('xs', 'int32', 1, True), ('ss', 'string', 2, True), ('qs', 'sint64', 3, True),
                        ('fs', 'fixed32', 4, True), ('kids', 'Big', 5, True), ('n', 'int32', 6, False)]}
    xs = [rand_scalar(rng, 'int32') for _ in range(count)]
    qs = [rand_scalar(rng, 'sint64') for _ in range(count)]
    fs = [rand_scalar(rng, 'fixed32') for _ in range(count)]
    ss = ['s%d' % i for i in range(count)]
    reqs = []
    packed = encode_value(rng, messages, 'Big', (('xs', xs),))
    if not full:
        reqs.append('encode Big {qs: %s}' % render(qs))
        reqs.append('decode Big ' + packed.hex())
        reqs.append('decode Big ' + encode_value(rng, messages, 'Big', (('xs', xs),), unpacked=1.0).hex())
        reqs.append('decode Big ' + packed[:-1].hex())
        return schema, reqs
    reqs.append('encode Big {xs: %s}' % render(xs))
    reqs.append('encode Big {qs: %s, fs: %s}' % (render(qs), render(fs)))
    reqs.append('encode Big {ss: %s}' % render(ss))
    reqs.append('decode Big ' + packed.hex())
    unpacked = encode_value(rng, messages, 'Big', (('xs', xs), ('qs', qs)), unpacked=1.0)
    reqs.append('decode Big ' + unpacked.hex())
    strings = encode_value(rng, messages, 'Big', (('ss', ss), ('fs', fs)))
    reqs.append('decode Big ' + strings.hex())
    kids = [(('n', i), ('xs', [i, -i])) for i in range(count)]
    reqs.append('encode Big {kids: %s}' % render(kids))
    reqs.append('decode Big ' + encode_value(rng, messages, 'Big', (('kids', kids),)).hex())
    # A truncated copy of the large packed payload must still be an error.
    reqs.append('decode Big ' + packed[:-1].hex())
    return schema, reqs


add('large_10k_repeated', *gen_big_repeated(301, 10_000))
add('large_100k_repeated', *gen_big_repeated(302, 100_000, full=False))


def gen_large_payload(seed):
    rng = random.Random(seed)
    schema = '''
message Doc { repeated Para paras = 1; string title = 2; Meta meta = 3; }
message Para { string text = 1; repeated int32 offsets = 2; repeated Span spans = 3; Meta meta = 4; }
message Span { uint32 start = 1; uint32 len = 2; string kind = 3; bytes raw = 4; bool bold = 5; }
message Meta { int64 ts = 1; repeated string tags = 2; sfixed64 hash = 3; }
'''
    messages = {
        'Doc': [('paras', 'Para', 1, True), ('title', 'string', 2, False), ('meta', 'Meta', 3, False)],
        'Para': [('text', 'string', 1, False), ('offsets', 'int32', 2, True), ('spans', 'Span', 3, True), ('meta', 'Meta', 4, False)],
        'Span': [('start', 'uint32', 1, False), ('len', 'uint32', 2, False), ('kind', 'string', 3, False), ('raw', 'bytes', 4, False), ('bold', 'bool', 5, False)],
        'Meta': [('ts', 'int64', 1, False), ('tags', 'string', 2, True), ('hash', 'sfixed64', 3, False)],
    }
    words = ['lorem', 'ipsum', 'dolor', 'sit', 'amet', 'ünïcode', '日本語', '😀', 'quote"', 'back\\slash', 'tab\t']
    paras = []
    for i in range(2500):
        text = ' '.join(rng.choice(words) for _ in range(rng.randint(5, 30)))
        spans = [(('start', rng.randint(0, 1000)), ('len', rng.randint(0, 50)), ('kind', rng.choice(['b', 'i', 'link'])),
                  ('raw', bytes(rng.randint(0, 255) for _ in range(rng.randint(0, 8)))), ('bold', rng.random() < 0.5))
                 for _ in range(rng.randint(0, 4))]
        para = [('text', text), ('offsets', [rng.randint(-1000, 1000) for _ in range(rng.randint(0, 10))]), ('spans', spans)]
        if rng.random() < 0.3:
            para.append(('meta', (('ts', rng.randint(0, 2 ** 40)), ('tags', ['t%d' % rng.randint(0, 9)]), ('hash', rng.randint(-2 ** 63, 2 ** 63 - 1)))))
        paras.append(tuple(para))
    doc = (('paras', paras), ('title', 'big document'), ('meta', (('ts', 1700000000), ('tags', ['big', 'test']))))
    reqs = ['encode Doc ' + render(doc)]
    data = encode_value(rng, messages, 'Doc', doc, noise=0.05, unpacked=0.3, nonminimal=0.1)
    reqs.append('decode Doc ' + data.hex())
    reqs.append('decode Doc ' + data[:len(data) // 2].hex())
    return schema, reqs


add('large_payload', *gen_large_payload(303))
add('many_requests', *gen_random_case(304, 6, 8, 20_000, noise=0.2, unpacked=0.3, nonminimal=0.1))


# ---------------------------------------------------------------------------
# Oracle: protoc + protobuf runtime, run in the oracle venv.
# ---------------------------------------------------------------------------
ORACLE_SCRIPT = r'''
import importlib, os, re, sys
sys.path.insert(0, sys.argv[1])
mod = importlib.import_module(sys.argv[2])
from google.protobuf.descriptor import FieldDescriptor as FD

class Fail(Exception):
    pass

class Parser:
    """Parses the text form into untyped Python values; strict about the spec's syntax."""
    def __init__(self, text):
        self.t = text
        self.i = 0
    def ws(self):
        while self.i < len(self.t) and self.t[self.i] == ' ':
            self.i += 1
    def peek(self):
        self.ws()
        if self.i >= len(self.t):
            raise Fail('eof')
        return self.t[self.i]
    def expect(self, c):
        if self.peek() != c:
            raise Fail('expected ' + c)
        self.i += 1
    def message(self):
        self.expect('{')
        pairs = []
        if self.peek() == '}':
            self.i += 1
            return tuple(pairs)
        while True:
            self.ws()
            j = self.i
            while self.i < len(self.t) and (self.t[self.i].isalnum() or self.t[self.i] == '_'):
                self.i += 1
            name = self.t[j:self.i]
            if not name or not name[0].isascii() or not all(c.isascii() for c in name):
                raise Fail('ident')
            if any(k == name for k, _ in pairs):
                raise Fail('dup')
            self.expect(':')
            pairs.append((name, self.value()))
            c = self.peek()
            self.i += 1
            if c == '}':
                return tuple(pairs)
            if c != ',':
                raise Fail(', or }')
    def value(self):
        c = self.peek()
        if c == '{':
            return self.message()
        if c == '[':
            self.i += 1
            items = []
            if self.peek() == ']':
                self.i += 1
                return items
            while True:
                items.append(self.value())
                c = self.peek()
                self.i += 1
                if c == ']':
                    return items
                if c != ',':
                    raise Fail(', or ]')
        if c == '"':
            return self.string()
        if self.t.startswith('x"', self.i):
            self.i += 2
            j = self.i
            while self.i < len(self.t) and self.t[self.i] in '0123456789abcdef':
                self.i += 1
            h = self.t[j:self.i]
            if self.i >= len(self.t) or self.t[self.i] != '"' or len(h) % 2:
                raise Fail('bytes')
            self.i += 1
            return bytes.fromhex(h)
        if self.t.startswith('true', self.i):
            self.i += 4
            return True
        if self.t.startswith('false', self.i):
            self.i += 5
            return False
        j = self.i
        if c == '-':
            self.i += 1
        k = self.i
        while self.i < len(self.t) and self.t[self.i] in '0123456789':
            self.i += 1
        d = self.t[k:self.i]
        if not d or (len(d) > 1 and d[0] == '0') or (c == '-' and int(d) == 0):
            raise Fail('int')
        return int(self.t[j:self.i])
    def string(self):
        self.expect('"')
        buf = bytearray()
        while True:
            if self.i >= len(self.t):
                raise Fail('unterminated')
            ch = self.t[self.i]
            self.i += 1
            if ch == '"':
                break
            if ch == '\\':
                if self.i >= len(self.t):
                    raise Fail('esc')
                e = self.t[self.i]
                self.i += 1
                simple = {'n': 10, 'r': 13, 't': 9, '"': 34, '\\': 92}
                if e in simple:
                    buf.append(simple[e])
                elif e == 'x':
                    hh = self.t[self.i:self.i + 2]
                    if len(hh) != 2 or any(c not in '0123456789abcdefABCDEF' for c in hh):
                        raise Fail('hex esc')
                    buf.append(int(hh, 16))
                    self.i += 2
                else:
                    raise Fail('esc')
            elif ord(ch) < 0x20:
                raise Fail('ctrl')
            else:
                buf += ch.encode('utf-8')
        try:
            return buf.decode('utf-8')
        except UnicodeDecodeError:
            raise Fail('utf8')
    def top(self):
        v = self.message()
        self.ws()
        if self.i != len(self.t):
            raise Fail('trailing')
        return v

def build(msg, pairs):
    """Fills a protobuf message from parsed pairs; raises on any type/range violation."""
    desc = msg.DESCRIPTOR
    for name, v in pairs:
        fd = desc.fields_by_name.get(name)
        if fd is None:
            raise Fail('unknown field ' + name)
        rep = fd.is_repeated
        if rep != isinstance(v, list):
            raise Fail('repeated mismatch')
        items = v if rep else [v]
        for item in items:
            if fd.type == FD.TYPE_MESSAGE:
                if not isinstance(item, tuple):
                    raise Fail('expected message')
                sub = getattr(msg, name).add() if rep else getattr(msg, name)
                if not rep:
                    sub.SetInParent()
                build(sub, item)
                continue
            if fd.type == FD.TYPE_BOOL:
                if not isinstance(item, bool):
                    raise Fail('expected bool')
            elif fd.type == FD.TYPE_STRING:
                if not isinstance(item, str):
                    raise Fail('expected string')
            elif fd.type == FD.TYPE_BYTES:
                if not isinstance(item, bytes):
                    raise Fail('expected bytes')
            elif isinstance(item, bool) or not isinstance(item, int):
                raise Fail('expected int')
            if rep:
                getattr(msg, name).append(item)
            else:
                setattr(msg, name, item)

def to_value(msg):
    """Message as a tuple of (name, value) pairs in field-number order; repeated fields as lists."""
    pairs = []
    for fd, v in msg.ListFields():
        if fd.is_repeated:
            if fd.type == FD.TYPE_MESSAGE:
                pairs.append((fd.name, [to_value(x) for x in v]))
            else:
                pairs.append((fd.name, list(v)))
        elif fd.type == FD.TYPE_MESSAGE:
            pairs.append((fd.name, to_value(v)))
        else:
            pairs.append((fd.name, v))
    return tuple(pairs)

def same(a, b):
    if type(a) is not type(b):
        return False
    if isinstance(a, (list, tuple)):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b

def field0_in_group(data, depth=0):
    """True when a field-number-0 tag occurs inside a group. The protobuf spec
    forbids field 0 everywhere, but upb only rejects it outside groups, so the
    suite excludes such streams and this scan enforces that exclusion."""
    pos = 0
    end = len(data)
    def read_varint(pos):
        v = 0
        shift = 0
        for i in range(10):
            if pos >= end:
                return None, pos
            b = data[pos]
            pos += 1
            v |= (b & 0x7F) << shift
            shift += 7
            if not b & 0x80:
                return v, pos
        return None, pos
    while pos < end:
        t, pos = read_varint(pos)
        if t is None:
            return False
        number, wire = t >> 3, t & 7
        if number == 0 and depth > 0:
            return True
        if wire == 0:
            v, pos = read_varint(pos)
            if v is None:
                return False
        elif wire == 1:
            pos += 8
        elif wire == 5:
            pos += 4
        elif wire == 2:
            n, pos = read_varint(pos)
            if n is None or n > end - pos:
                return False
            if field0_in_group(data[pos:pos + n], 0):
                return True
            pos += n
        elif wire == 3:
            depth += 1
        elif wire == 4:
            depth -= 1
        else:
            return False
    return False

exempt = 0

def check(line, expected):
    global exempt
    kind, rest = line.split(' ', 1)
    name, _, arg = rest.partition(' ')
    cls = getattr(mod, name)
    if kind == 'decode':
        # The line must be exactly `decode <Name>` or `decode <Name> <hex>` with
        # well-formed lowercase hex; anything else is an error before decoding.
        parts = line.split(' ')
        if len(parts) > 3 or (len(parts) == 3 and not re.fullmatch('([0-9a-f]{2})+', parts[2])):
            return expected == 'error'
        m = cls()
        try:
            m.ParseFromString(bytes.fromhex(arg))
        except Exception:
            return expected == 'error'
        if expected == 'error':
            if field0_in_group(bytes.fromhex(arg)):
                exempt += 1
                return True
            return False
        try:
            got = Parser(expected).top()
        except Fail:
            return False
        return same(to_value(m), got)
    m = cls()
    try:
        pairs = Parser(arg).top()
    except Fail:
        return expected == 'error'
    try:
        build(m, pairs)
    except (Fail, ValueError, TypeError, OverflowError):
        return expected == 'error'
    return m.SerializeToString().hex() == expected

fails = 0
with open(sys.argv[3], encoding='utf-8') as f:
    lines = f.read().split('\n')
with open(sys.argv[4], encoding='utf-8') as f:
    outs = f.read().split('\n')
if outs and outs[-1] == '':
    outs.pop()
reqs = [l for l in lines[lines.index('--') + 1:] if l != '']
if len(reqs) != len(outs):
    print('request/output count mismatch: %d vs %d' % (len(reqs), len(outs)))
    sys.exit(1)
for line, out in zip(reqs, outs):
    if not check(line, out):
        fails += 1
        if fails <= 5:
            print('ORACLE DISAGREES: %s -> %r' % (line[:120], out[:120]))
print('%d requests checked, %d disagreements%s' % (len(reqs), fails, ', %d field-0-in-group streams excluded' % exempt if exempt else ''))
sys.exit(1 if fails else 0)
'''


def schema_to_proto(schema_text, package):
    body = schema_text.replace('\n', ' ')
    return 'syntax = "proto3";\npackage %s;\n%s\n' % (package, body)


def oracle_check(idx, input_text, in_path, out_path, workdir):
    package = 't%03d' % idx
    schema_text = input_text[:input_text.index('\n--\n')]
    proto_path = os.path.join(workdir, package + '.proto')
    with open(proto_path, 'w', encoding='utf-8') as f:
        f.write(schema_to_proto(schema_text, package))
    subprocess.run([PROTOC, '-I', workdir, '--python_out', workdir, proto_path], check=True)
    script = os.path.join(workdir, 'oracle.py')
    with open(script, 'w', encoding='utf-8') as f:
        f.write(ORACLE_SCRIPT)
    proc = subprocess.run([ORACLE_PY, script, workdir, package + '_pb2', in_path, out_path],
                          capture_output=True, text=True, timeout=1200)
    sys.stdout.write(proc.stdout)
    if proc.returncode != 0:
        sys.stdout.write(proc.stderr)
        raise SystemExit('oracle disagreement in test %d' % idx)


def run_reference(data):
    proc = subprocess.run([sys.executable, REF], input=data, capture_output=True, timeout=600)
    assert proc.returncode == 0, proc.stderr.decode()
    return proc.stdout


def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith('.in') or f.endswith('.out'):
            os.remove(os.path.join(TESTS, f))
    workdir = tempfile.mkdtemp(prefix='protowire_oracle_')
    names = set()
    try:
        for idx, (name, text) in enumerate(cases, 1):
            assert name not in names, name
            names.add(name)
            base = '%03d_%s' % (idx, name)
            data = text.encode('utf-8')
            out = run_reference(data)
            in_path = os.path.join(TESTS, base + '.in')
            out_path = os.path.join(TESTS, base + '.out')
            with open(in_path, 'wb') as f:
                f.write(data)
            with open(out_path, 'wb') as f:
                f.write(out)
            n_req = text[text.index('\n--\n') + 4:].count('\n')
            print('%-32s %9d bytes in, %9d bytes out, %6d requests' % (base, len(data), len(out), n_req))
            oracle_check(idx, text, in_path, out_path, workdir)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    print('%d tests written' % len(cases))


if __name__ == '__main__':
    main()
