#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `json` problem.

Every test is either an embedded literal (edge cases) or produced by a
seeded generator, so re-running this script reproduces the suite exactly.
Expected outputs come from reference/main.py; the Python `json` module is
used as an independent oracle to cross-check validity, values, key order
and idempotence of every expected output.
"""
import json
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
REF = os.path.join(HERE, 'reference', 'main.py')
MAX_DEPTH = 512

cases = []


def add(name, data):
    if isinstance(data, str):
        data = data.encode('utf-8')
    cases.append((name, data))


# ---------------------------------------------------------------------------
# Hand-written edge cases (valid)
# ---------------------------------------------------------------------------
add('empty_object', '{}')
add('empty_array', ' \t\r\n[ \n ] \r\n')
add('literals', '[ true , false , null ]')
add('scalar_number_top', '  42  \n')
add('scalar_string_top', '"hello, world"')
add('scalar_literal_top', 'null')
add('nested_mixed', '''{
  "name": "langbench",
  "tags": ["a", "b", "c"],
  "nested": {"z": {"y": {"x": [1, [2, [3, {}]]]}}},
  "count": 3,
  "ok": true,
  "nothing": null
}''')
add('key_sorting_ascii', '{"b":1,"a":2,"B":3,"":4,"aa":5,"a a":6,"a":7,"_":8,"0":9,"~":10,"A":11}')
add('duplicate_keys_last_wins', '{"a":1,"b":2,"a":3,"c":{"x":1,"x":2,"x":[3]},"a":4,"b":{"q":true}}')
add('duplicate_keys_by_decoded_value', '{"a":1,"\\u0061":2,"\\u00e9":"esc","é":"raw","\\ud83d\\ude00":1,"😀":2}')
add('utf16_key_order', '{"\\uE000":1,"😀":2,"\\uFFFF":3,"Z":4,"é":5,"\\ud800\\udc00":6,"\\uD7FF":7,"a":8}')
add('string_escapes', '["\\"quote\\"", "back\\\\slash", "sl\\/ash", "\\b\\f\\n\\r\\t", "\\u0041\\u0062\\u0063", "\\u001f\\u0001\\u007f\\u0000", "\\u00e9\\u65E5\\u672c", "\\u2028\\u2029"]')
add('surrogate_pair_escaped', '["\\uD83D\\uDE00", "\\ud83d\\ude00x", "a\\uD834\\uDD1Eb", "\\uDBFF\\uDFFF", "\\uD800\\uDC00"]')
add('raw_unicode', '{"日本語":"テキスト","emoji":"😀🎉👍","mixed":"a€b𝄞c","é":"ü","\u007f":"del"}')
add('numbers_integers', '[0,-0,1,-1,10,-10,123456789012345678901234567890,-98765432109876543210987654321098765432109876543210,9007199254740993]')
add('numbers_normalized', '[1.0,1.50,1E5,1e+5,1E-5,1e-0,1e-00,1e007,1.5e+007,-0.0,0.0e0,0e0,2.5E-000789,1e0000000000,123.456e-000789,-1.25E+10,0.000001,100e2]')
add('numbers_zero_exponent', '[1e0,1e-0,1E+0,1e00,1E-000,0e-0,1.5e+0]')
add('numbers_huge', '[' + '1' * 1000 + ',' + '-' + '9' * 500 + '.' + '0' * 200 + 'E+' + '0' * 50 + '7' * 30 + ']')
add('escaped_nul', '["\\u0000", "a\\u0000b"]')
add('control_char_escape_lowercase', '["\\u001F\\u000B\\u001A\\u0008\\u000C\\u000A\\u000D\\u0009"]')
add('whitespace_everywhere', ' \r\n\t{ \r\n\t"a" \r\n\t: \r\n\t[ \r\n\t1 \r\n\t, \r\n\t"b" \r\n\t] \r\n\t, \r\n\t"c" \r\n\t: \r\n\t{ \r\n\t} \r\n\t} \r\n\t')
add('empty_key_and_empty_string', '{"":"", "x":[""," ","  "]}')
add('string_with_del_and_slash', '["/", "\\/", "a/b\\/c", "\x7f"]')
add('deep_512_arrays', '[' * 512 + ']' * 512)
add('deep_512_objects', '{"a":' * 512 + '1' + '}' * 512)
add('deep_512_mixed_with_siblings', '[1,{"k":' * 256 + '0' + ',"j":2}]' * 256)
add('key_prefix_and_nul_ordering', '{"ab":1,"a":2,"a\\u0000":3,"":4,"a ":5,"a\\u0001":6,"b":7}')
add('numbers_negative_zero_forms', '[-0,-0.0,-0e0,-0.0E+0,-0e-0,-0E-00,-0.00e+000]')
add('escaped_key_dedup_and_escape_output', '{"\\"":1,"\\\\":2,"\\/":3,"/":4,"\\u0022":5,"\\n":6,"\\u000a":7,"\\u007f":8}')
add('depth_512_empty_innermost', '[' * 511 + '{}' + ']' * 511)

# ---------------------------------------------------------------------------
# Hand-written edge cases (invalid)
# ---------------------------------------------------------------------------
add('invalid_empty_input', b'')
add('invalid_whitespace_only', b' \n\t\r\n ')
add('invalid_trailing_comma_array', '[1,2,]')
add('invalid_trailing_comma_object', '{"a":1,}')
add('invalid_leading_comma', '[,1]')
add('invalid_double_comma', '[1,,2]')
add('invalid_leading_zero', '[01]')
add('invalid_negative_leading_zero', '-012')
add('invalid_minus_alone', '[-]')
add('invalid_one_dot', '[1.]')
add('invalid_dot_five', '[.5]')
add('invalid_one_e', '[1e]')
add('invalid_one_e_plus', '1e+')
add('invalid_plus_sign', '[+1]')
add('invalid_hex_number', '[0x1F]')
add('invalid_nan', '[NaN]')
add('invalid_infinity', '[-Infinity]')
add('invalid_true_capitalized', '[True]')
add('invalid_truncated_literal', '[nul]')
add('invalid_literal_suffix', 'truex')
add('invalid_bom', b'\xef\xbb\xbf{}')
add('invalid_unescaped_tab', b'["a\tb"]')
add('invalid_unescaped_newline', b'["a\nb"]')
add('invalid_raw_nul_in_string', b'["a\x00b"]')
add('invalid_utf8_byte_ff', b'["\xff"]')
add('invalid_utf8_truncated', b'["\xe6\x97"]')
add('invalid_utf8_overlong', b'["\xc0\xaf"]')
add('invalid_utf8_encoded_surrogate', b'["\xed\xa0\x80"]')
add('invalid_utf8_above_10ffff', b'["\xf4\x90\x80\x80"]')
add('invalid_utf8_outside_string', b'[1,\xc3\xa9]')
add('invalid_lone_high_surrogate', '["\\uD800"]')
add('invalid_lone_low_surrogate', '["\\uDC00"]')
add('invalid_surrogate_then_bmp', '["\\uD800\\u0041"]')
add('invalid_surrogate_then_raw', '["\\uD83D😀"]')
add('invalid_reversed_surrogates', '["\\uDE00\\uD83D"]')
add('invalid_bad_escape', '["\\x41"]')
add('invalid_truncated_unicode_escape', '["\\u12"]')
add('invalid_nonhex_unicode_escape', '["\\u12G4"]')
add('invalid_unicode_escape_with_sign', '["\\u+123"]')
add('invalid_single_quotes', "['a']")
add('invalid_unquoted_key', '{a:1}')
add('invalid_numeric_key', '{1:2}')
add('invalid_missing_colon', '{"a" 1}')
add('invalid_missing_comma', '[1 2]')
add('invalid_trailing_content', '{} x')
add('invalid_two_documents', '[] []')
add('invalid_number_then_garbage', '123abc')
add('invalid_unterminated_string', '["abc')
add('invalid_unterminated_object', '{"a":1')
add('invalid_unterminated_array', '[1,2')
add('invalid_line_comment', '[1]//c')
add('invalid_block_comment', '/*c*/[1]')
add('invalid_formfeed_whitespace', b'[1\x0c]')
add('invalid_nbsp_whitespace', '[1 ]')
add('invalid_deep_513_arrays', '[' * 513 + ']' * 513)
add('invalid_deep_513_objects', '{"a":' * 513 + '1' + '}' * 513)
add('invalid_deep_100000_unclosed', '[' * 100000)
add('invalid_deep_open_array_object', '[{"":' * 50000)
add('invalid_deep_512_unclosed', '[' * 512)
add('invalid_raw_unit_separator_in_string', b'["\x1f"]')
add('invalid_raw_ctrl_at_string_end', b'["abc\x1e"]')
add('invalid_vertical_tab_whitespace', b'[1\x0b]')
add('invalid_line_separator_whitespace', '[1\u2028]')
add('invalid_nel_whitespace', '[1\u0085]')
add('invalid_unicode_digit_in_int', '[1\u0662]')
add('invalid_unicode_digit_in_frac', '[1.\u0662]')
add('invalid_unicode_digit_in_exp', '[1e\u0662]')
add('invalid_superscript_digit', '[1\u00b2]')
add('invalid_fullwidth_hex_in_escape', '["\\u00\uff11\uff12"]')
add('invalid_high_surrogate_then_e000', '["\\uD800\\uE000"]')
add('invalid_high_surrogate_then_high', '["\\uD800\\uDBFF"]')
add('invalid_two_high_surrogates_dbff', '["\\uDBFF\\uDBFF"]')
add('invalid_minus_space_digit', '[- 1]')
add('invalid_space_inside_number', '[1 .5]')
add('invalid_double_exponent', '[1e5e5]')
add('invalid_exponent_two_signs', '[1E+-5]')
add('invalid_backslash_at_eof', '["\\')
add('invalid_trailing_nul_byte', b'{}\x00')
add('invalid_overridden_value_lone_surrogate', '{"a":"\\uD800","a":1}')
add('invalid_overridden_value_too_deep', '{"a":' + '[' * 513 + ']' * 513 + ',"a":1}')
add('invalid_overridden_value_bad_syntax', '{"a":[1,],"a":1}')
add('invalid_lone_surrogate_in_key', '{"\\uDC00":1}')
add('invalid_deep_513_empty_innermost', '[' * 512 + '{}' + ']' * 512)

# ---------------------------------------------------------------------------
# Generated documents
# ---------------------------------------------------------------------------
STRING_ALPHABET = (
    [chr(c) for c in range(0x20, 0x7f)] * 6
    + ['\x7f', '\t', '\n', '\r', '\b', '\f', '\x00', '\x01', '\x1f', '\x0b']
    + ['é', 'ü', 'ß', '日', '本', '語', '€', ' ', ' ', '', '￿', '퟿', '\u0080', ' ']
    + ['😀', '🎉', '𝄞', '\U0010ffff', '\U00010000']
)


class Num(str):
    """A number lexeme kept verbatim so its exact input spelling is controlled."""


def rand_string(rng, maxlen=12):
    n = rng.randint(0, maxlen)
    return ''.join(rng.choice(STRING_ALPHABET) for _ in range(n))


def rand_number(rng):
    r = rng.random()
    sign = '-' if rng.random() < 0.3 else ''
    if r < 0.4:
        digits = str(rng.randint(0, 10 ** rng.choice([1, 3, 6, 12, 20, 40])))
        return Num(sign + digits)
    intpart = str(rng.randint(0, 10 ** rng.choice([1, 2, 5, 9])))
    frac = ''
    if rng.random() < 0.7:
        frac = '.' + ''.join(rng.choice('0123456789') for _ in range(rng.randint(1, 8)))
    exp = ''
    if rng.random() < 0.6 or not frac:
        e = rng.choice('eE')
        esign = rng.choice(['', '+', '-', '-', ''])
        zeros = '0' * rng.choice([0, 0, 0, 1, 2, 5])
        edigits = str(rng.choice([0, 0, 1, 5, 12, 300, 4096]))
        exp = e + esign + zeros + edigits
    return Num(sign + intpart + frac + exp)


def rand_value(rng, depth, max_depth, fanout):
    r = rng.random()
    if depth >= max_depth or r < 0.45:
        k = rng.random()
        if k < 0.35:
            return rand_string(rng)
        if k < 0.75:
            return rand_number(rng)
        return rng.choice([True, False, None])
    n = rng.randint(0, fanout)
    if r < 0.72:
        return [rand_value(rng, depth + 1, max_depth, fanout) for _ in range(n)]
    pairs = []
    for _ in range(n):
        pairs.append((rand_string(rng, 8), rand_value(rng, depth + 1, max_depth, fanout)))
    # Occasionally duplicate an existing key with a different value.
    if pairs and rng.random() < 0.3:
        k = rng.choice(pairs)[0]
        pairs.append((k, rand_value(rng, depth + 1, max_depth, fanout)))
    return ('obj', pairs)


SIMPLE_OUT = {'"': '\\"', '\\': '\\\\', '\b': '\\b', '\f': '\\f', '\n': '\\n', '\r': '\\r', '\t': '\\t'}


def emit_string(rng, s, out):
    """Serializes a string with randomly varied but valid escaping."""
    out.append('"')
    for ch in s:
        cp = ord(ch)
        r = rng.random()
        if ch in SIMPLE_OUT and (cp >= 0x20 or r < 0.7):
            out.append(SIMPLE_OUT[ch])
        elif cp < 0x20:
            fmt = '\\u%04x' if r < 0.5 else '\\u%04X'
            out.append(fmt % cp)
        elif ch == '/' and r < 0.4:
            out.append('\\/')
        elif cp >= 0x10000 and r < 0.4:
            v = cp - 0x10000
            hi, lo = 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF)
            fmt = '\\u%04x\\u%04x' if rng.random() < 0.5 else '\\u%04X\\u%04X'
            out.append(fmt % (hi, lo))
        elif cp >= 0x80 and r < 0.3:
            out.append(('\\u%04x' if rng.random() < 0.5 else '\\u%04X') % cp)
        elif cp < 0x80 and r < 0.03:
            out.append('\\u%04x' % cp)
        else:
            out.append(ch)
    out.append('"')


WS_CHOICES = ['', ' ', ' ', '\n', '\t', '  ', '\r\n', '\n    ', ' \t ']


def emit(rng, v, out, pretty, indent=0):
    ws = (lambda: rng.choice(WS_CHOICES)) if pretty else (lambda: '')
    if isinstance(v, Num):
        out.append(str(v))
    elif isinstance(v, bool):
        out.append('true' if v else 'false')
    elif v is None:
        out.append('null')
    elif isinstance(v, str):
        emit_string(rng, v, out)
    elif isinstance(v, list):
        out.append('[')
        out.append(ws())
        for idx, item in enumerate(v):
            if idx:
                out.append(',')
                out.append(ws())
            if pretty and rng.random() < 0.5:
                out.append('\n' + ' ' * (indent + 2))
            emit(rng, item, out, pretty, indent + 2)
            out.append(ws())
        out.append(']')
    else:
        _, pairs = v
        out.append('{')
        out.append(ws())
        for idx, (k, item) in enumerate(pairs):
            if idx:
                out.append(',')
                out.append(ws())
            if pretty and rng.random() < 0.5:
                out.append('\n' + ' ' * (indent + 2))
            emit_string(rng, k, out)
            out.append(ws())
            out.append(':')
            out.append(ws())
            emit(rng, item, out, pretty, indent + 2)
            out.append(ws())
        out.append('}')


def gen_document(seed, target_size, pretty, max_depth=8, fanout=5):
    """Builds a top-level array of random values until it reaches target_size bytes."""
    rng = random.Random(seed)
    out = ['[']
    size = 1
    first = True
    while size < target_size:
        if not first:
            out.append(',')
            if pretty:
                out.append('\n')
        first = False
        chunk = []
        emit(rng, rand_value(rng, 0, max_depth, fanout), chunk, pretty)
        piece = ''.join(chunk)
        out.append(piece)
        size += len(piece.encode('utf-8')) + 2
    out.append(']')
    return ''.join(out)


add('gen_small_compact', gen_document(1, 2_000, pretty=False, max_depth=6, fanout=5))
add('gen_small_pretty', gen_document(2, 4_000, pretty=True, max_depth=6, fanout=5))
add('gen_medium_compact', gen_document(3, 100_000, pretty=False))
add('gen_medium_pretty', gen_document(4, 150_000, pretty=True))

# Many objects with duplicate keys and key sets that exercise UTF-16 ordering.
def gen_objects(seed, count):
    rng = random.Random(seed)
    keys_pool = ['', 'a', 'A', 'Z', 'z', 'aa', 'ab', 'a\u0000', 'é', 'ÿ', 'Ā', '퟿', '', '￿',
                 '😀', '\U00010000', '\U0010ffff', '日本', '/', '\\', '"', '\t', 'key', 'Key', 'KEY', '_', '0', '9']
    out = ['[']
    for i in range(count):
        if i:
            out.append(',')
        n = rng.randint(0, 10)
        pairs = []
        for _ in range(n):
            k = rng.choice(keys_pool) + (rng.choice(['', 'x', rand_string(rng, 3)]) if rng.random() < 0.3 else '')
            pairs.append((k, rand_value(rng, 0, 2, 3)))
        chunk = []
        emit(rng, ('obj', pairs), chunk, pretty=rng.random() < 0.5)
        out.append(''.join(chunk))
    out.append(']')
    return ''.join(out)


add('gen_objects_utf16_order_and_dups', gen_objects(5, 2000))


def gen_flat_object(seed, count):
    """One object with many keys, ~10% duplicates, sorted output is a large permutation."""
    rng = random.Random(seed)
    keys = []
    for i in range(count):
        keys.append(rand_string(rng, 10) + str(i))
    pairs = []
    for i in range(count):
        k = keys[i] if rng.random() > 0.1 else rng.choice(keys)
        pairs.append((k, rand_value(rng, 0, 1, 2)))
    chunk = []
    emit(rng, ('obj', pairs), chunk, pretty=False)
    return ''.join(chunk)


add('gen_large_flat_object', gen_flat_object(6, 30_000))


def gen_numbers(seed, count):
    rng = random.Random(seed)
    return '[' + ','.join(rand_number(rng) for _ in range(count)) + ']'


add('gen_large_numbers', gen_numbers(7, 80_000))


def gen_strings(seed, count, length):
    rng = random.Random(seed)
    out = ['[']
    for i in range(count):
        if i:
            out.append(',')
        emit_string(rng, rand_string(rng, length), out)
    out.append(']')
    return ''.join(out)


add('gen_large_strings', gen_strings(8, 600, 1500))
add('gen_large_compact', gen_document(9, 1_000_000, pretty=False))
add('gen_large_pretty', gen_document(10, 1_000_000, pretty=True))

# Wide and deep at once: 512 nested arrays where each level carries siblings.
def gen_deep_wide():
    rng = random.Random(11)
    out = []
    for d in range(MAX_DEPTH):
        chunk = []
        emit(rng, rand_value(rng, 0, 0, 0), chunk, pretty=False)
        out.append('[' + ''.join(chunk) + ',')
    out.append('"bottom"')
    for d in range(MAX_DEPTH):
        chunk = []
        if d == 0:
            # The innermost array is already at depth 512, so it may only hold scalars.
            emit(rng, rand_number(rng), chunk, pretty=False)
        else:
            emit(rng, ('obj', [(rand_string(rng, 4), rand_number(rng)), ('', None)]), chunk, pretty=False)
        out.append(',' + ''.join(chunk) + ']')
    return ''.join(out)


add('gen_deep_wide_512', gen_deep_wide())
add('gen_deep_wide_513_invalid', '[' + gen_deep_wide() + ']')

# A large document that is valid until the very end: nothing partial may be printed.
big = gen_document(12, 800_000, pretty=False)
add('gen_large_invalid_trailing_comma', big[:-1] + ',]')
add('gen_large_invalid_bad_utf8_at_end', big.encode('utf-8')[:-1] + b'\xff]')
add('gen_large_invalid_control_char_at_end', big[:-1] + ', "x\x01y"]')


# ---------------------------------------------------------------------------
# Oracle (Python json module) used only to cross-check the reference.
# ---------------------------------------------------------------------------
INVALID = object()
UNKNOWN = object()


class Pairs(list):
    """Object members as an ordered list of (key, value), duplicates included."""


def _reject_constant(_):
    raise ValueError('NaN/Infinity')


def oracle(data):
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return INVALID
    if text.startswith('﻿'):
        return INVALID
    try:
        value = json.loads(text, parse_constant=_reject_constant, object_pairs_hook=Pairs)
    except RecursionError:
        return UNKNOWN
    except ValueError:
        return INVALID
    # Extra rules the json module does not enforce: lone surrogates, max depth.
    # Every member is checked, including values that a later duplicate key overrides.
    def walk(v, depth):
        if isinstance(v, str):
            return not any(0xD800 <= ord(c) <= 0xDFFF for c in v)
        if isinstance(v, Pairs):
            return depth < MAX_DEPTH and all(walk(k, depth) and walk(x, depth + 1) for k, x in v)
        if isinstance(v, list):
            return depth < MAX_DEPTH and all(walk(x, depth + 1) for x in v)
        return True

    def to_value(v):
        if isinstance(v, Pairs):
            return {k: to_value(x) for k, x in v}
        if isinstance(v, list):
            return [to_value(x) for x in v]
        return v
    return to_value(value) if walk(value, 0) else INVALID


def same(a, b):
    if type(a) is not type(b):
        return False
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


def check_canonical_text(text):
    """Checks structural properties of a canonical output: sorted unique keys, no whitespace."""
    def hook(pairs):
        keys = [k for k, _ in pairs]
        assert len(set(keys)) == len(keys), 'duplicate key in output'
        assert keys == sorted(keys, key=lambda k: k.encode('utf-16-be')), 'keys not in UTF-16 order'
        return dict(pairs)
    json.loads(text, object_pairs_hook=hook)


def run_reference(data):
    proc = subprocess.run([sys.executable, REF], input=data, capture_output=True, timeout=300)
    assert proc.returncode == 0, proc.stderr.decode()
    return proc.stdout


def main():
    sys.setrecursionlimit(20000)
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith('.in') or f.endswith('.out'):
            os.remove(os.path.join(TESTS, f))
    names = set()
    for idx, (name, data) in enumerate(cases, 1):
        assert name not in names, name
        names.add(name)
        base = '%03d_%s' % (idx, name)
        out = run_reference(data)
        assert out.endswith(b'\n') and b'\n' not in out[:-1], base
        with open(os.path.join(TESTS, base + '.in'), 'wb') as f:
            f.write(data)
        with open(os.path.join(TESTS, base + '.out'), 'wb') as f:
            f.write(out)
        # Cross-check against the oracle.
        expect = oracle(data)
        if out == b'invalid\n':
            assert expect is INVALID or expect is UNKNOWN, 'reference says invalid, oracle disagrees: ' + base
            assert name.startswith('invalid') or 'invalid' in name, 'unexpected invalid: ' + base
        else:
            assert expect is not INVALID, 'reference says valid, oracle says invalid: ' + base
            text = out[:-1].decode('utf-8')
            check_canonical_text(text)
            if expect is not UNKNOWN:
                assert same(json.loads(text), expect), 'value mismatch: ' + base
            assert run_reference(out[:-1]) == out, 'not idempotent: ' + base
        print('%-45s %9d bytes -> %s' % (base, len(data), out[:60].decode('utf-8', 'replace').rstrip()))
    print('%d tests written' % len(cases))


if __name__ == '__main__':
    main()
