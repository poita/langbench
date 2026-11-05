#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `toml` problem.

Test material comes from three places:

* corpus/toml-test — the official toml-test suite restricted to the files
  listed in files-toml-1.0.0.  Each valid case becomes a decode test whose
  expected output is checked against the suite's own .json file, and each
  invalid case becomes a decode test that must print "error".
* corpus/real-world — Cargo.toml / Cargo.lock / pyproject.toml files taken
  from popular MIT-licensed projects.
* hand-written cases embedded below, plus a large document built from a
  fixed seed.

Expected outputs are produced by reference/main.py and cross-checked against
Python's tomllib (an independent TOML 1.0.0 implementation) and, for the
toml-test cases, against the suite's expected JSON.  Any disagreement aborts.
"""
import datetime
import json
import os
import shutil
import random
import subprocess
import sys

try:
    import tomllib
except ImportError:
    sys.exit('gen_tests.py needs Python 3.11+ for the tomllib oracle')

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
REF = os.path.join(HERE, 'reference', 'main.py')
SUITE = os.path.join(HERE, 'corpus', 'toml-test')
REAL = os.path.join(HERE, 'corpus', 'real-world')

sys.path.insert(0, os.path.join(HERE, 'reference'))
import main as ref  # noqa: E402  (used only for its float formatter)

# name -> (mode, document bytes, oracle policy)
cases = []


def add(name, mode, body, oracle=True):
    """Registers one test; body is the document that follows the mode line."""
    if isinstance(body, str):
        body = body.encode('utf-8')
    cases.append((name, mode, body, oracle))


# ---------------------------------------------------------------------------
# Hand-written decode cases
# ---------------------------------------------------------------------------

add('hand_empty_document', 'decode', '')
add('hand_single_pair', 'decode', 'a = 1\n')
add('hand_scalar_types', 'decode', '''
s = "hello"
i = 42
f = 3.5
b = true
odt = 1979-05-27T07:32:00Z
ldt = 1979-05-27T07:32:00
ld = 1979-05-27
lt = 07:32:00
'''.lstrip())
add('hand_string_escapes', 'decode',
    'a = "\\b\\t\\n\\f\\r\\"\\\\"\nb = "\\u00e9\\u0041\\U0001F600"\n'
    'c = "tab\\there"\nd = "nul\\u0000end"\n')
add('hand_literal_strings', 'decode',
    "a = 'C:\\\\Users\\\\nodejs'\nb = 'quoted \"value\"'\nc = ''\n")
add('hand_multiline_basic', 'decode',
    'a = """\nRoses are red\nViolets are blue"""\n'
    'b = """here are two quotes: ""."""\n'
    'c = """""\"""\"""\n')
add('hand_multiline_backslash', 'decode',
    'a = """\\\n     The quick brown \\\n     fox jumps over \\\n'
    '     the lazy dog.\\\n     """\nb = """x\\\n\ty"""\n')
add('hand_multiline_literal', 'decode',
    "a = '''\nI [dw]on't need \\d{2} apples'''\nb = '''''can't stop'''\n")
add('hand_multiline_crlf', 'decode',
    b'a = """one\r\ntwo"""\r\nb = \'\'\'three\r\nfour\'\'\'\r\n')
add('hand_keys', 'decode',
    'bare_key = 1\nbare-key = 2\n1234 = 3\n"127.0.0.1" = 4\n'
    '"\\u00e9" = 5\n\'quoted "value"\' = 6\n"" = 7\n\'\' = 8\n'
    'physical.color = "orange"\nphysical.shape = "round"\n'
    'site."google.com" = true\n')
add('hand_integers', 'decode',
    'dec1 = +99\ndec2 = 42\ndec3 = 0\ndec4 = -17\ngrouped = 1_000_000\n'
    'hex1 = 0xDEADBEEF\nhex2 = 0xdead_beef\noct = 0o01234567\n'
    'oct2 = 0o755\nbin = 0b11010110\n'
    'maxi = 9223372036854775807\nmini = -9223372036854775808\n')
add('hand_floats', 'decode',
    'f1 = +1.0\nf2 = 3.1415\nf3 = -0.01\nf4 = 5e+22\nf5 = 1e06\nf6 = -2E-2\n'
    'f7 = 6.626e-34\nf8 = 224_617.445_991_228\nzero = 0.0\nnzero = -0.0\n'
    'pinf = +inf\nninf = -inf\nn1 = nan\nn2 = -nan\nsmall = 5e-324\n'
    'big = 1.7976931348623157e308\nthird = 0.3333333333333333\n')
add('hand_datetimes', 'decode',
    'a = 1979-05-27T07:32:00Z\nb = 1979-05-27 07:32:00z\n'
    'c = 1979-05-27T00:32:00.999999-07:00\nd = 1979-05-27T00:32:00.100+00:00\n'
    'e = 1979-05-27t07:32:00.000\nf = 2024-02-29\ng = 00:00:00\n'
    'h = 23:59:59.500000\ni = 1979-05-27T07:32:00-00:00\n')
add('hand_arrays', 'decode',
    'a = []\nb = [1, 2, 3]\nc = [ "red", "yellow", "green" ]\n'
    'd = [ [ 1, 2 ], ["a", "b", "c"] ]\ne = [ 0.1, 1, "x", true ]\n'
    'f = [\n  1,\n  2, # trailing comment\n]\n'
    'g = [[[[[]]]]]\nh = [{x = 1}, {y = 2}]\n')
add('hand_inline_tables', 'decode',
    'empty = {}\nname = { first = "Tom", last = "Preston-Werner" }\n'
    'point = { x = 1, y = 2 }\nanimal = { type.name = "pug" }\n'
    'nested = { a = { b = { c = 1 } } }\n')
add('hand_tables', 'decode',
    '[table-1]\nkey1 = "some string"\nkey2 = 123\n\n'
    '[table-2]\nkey1 = "another string"\n\n'
    '[dog."tater.man"]\ntype.name = "pug"\n\n'
    '[x.y.z.w]\n[x]\na = 1\n')
add('hand_array_of_tables', 'decode',
    '[[products]]\nname = "Hammer"\nsku = 738594937\n\n[[products]]\n\n'
    '[[products]]\nname = "Nail"\nsku = 284758393\n\n'
    '[[fruits]]\nname = "apple"\n\n[fruits.physical]\ncolor = "red"\n\n'
    '[[fruits.varieties]]\nname = "red delicious"\n\n'
    '[[fruits.varieties]]\nname = "granny smith"\n\n'
    '[[fruits]]\nname = "banana"\n\n[[fruits.varieties]]\nname = "plantain"\n')
add('hand_comments_and_blanks', 'decode',
    '# top comment\n\n\n   # indented\nkey = "value" # inline comment\n'
    '\t\n[t] # after header\n  x = 1\n# trailing comment without newline')
add('hand_unicode', 'decode',
    'greek = "\u03b1\u03b2\u03b3"\nemoji = "\U0001F600\U0001F44D"\n'
    'cjk = "\u4e2d\u6587"\n"\u00e9\u00e8" = "accents"\n'
    '[\u00fcml\u00e4ut]\nsnowman = "\u2603"\n')
add('hand_type_value_table', 'decode',
    'type = "not a tag"\nvalue = "also not a tag"\n\n'
    '[inner]\ntype = "string"\nvalue = "1"\n')
add('hand_crlf_document', 'decode', b'a = 1\r\n\r\n[t]\r\nb = "two"\r\n')
add('hand_deep_nesting', 'decode',
    'a = ' + '[' * 40 + ']' * 40 + '\n[' + '.'.join('k%d' % i for i in range(30)) + ']\nx = 1\n')

add('hand_key_order_codepoint', 'decode',
    'a = 1\n"\ue000" = 2\n"\ufffd" = 3\n"\U00010000" = 4\n"\U0001f600" = 5\n'
    '[t]\ninline = { "\U0001f600" = 1, "\ufffd" = 2, "\ue000" = 3 }\n'
    '"\U0001f600".x = 6\n"\ufffd".x = 7\n')

add('hand_err_unterminated_string', 'decode', 'a = "abc\n')
add('hand_err_duplicate_key', 'decode', 'a = 1\na = 2\n')
add('hand_err_bare_cr', 'decode', b'a = 1\rb = 2\n')
add('hand_err_leading_bom', 'decode', b'\xef\xbb\xbfa = 1\n')
add('hand_err_second_60', 'decode', 'a = 1979-05-27T23:59:60Z\n')
add('hand_err_year_zero', 'decode', 'a = 0000-01-01\n')
add('hand_err_feb_30', 'decode', 'a = 2024-02-30\n')
add('hand_err_offset_hour', 'decode', 'a = 1979-05-27T07:32:00+24:00\n')
add('hand_err_bad_utf8', 'decode', b'a = "\xff\xfe"\n')
add('hand_err_int_overflow', 'decode', 'a = 9223372036854775808\n', oracle=False)
add('hand_err_int_underflow', 'decode', 'a = -9223372036854775809\n', oracle=False)
add('hand_err_hex_overflow', 'decode', 'a = 0xFFFFFFFFFFFFFFFF\n', oracle=False)
add('hand_err_inline_newline', 'decode', 'a = {\n  b = 1\n}\n')
add('hand_err_inline_trailing_comma', 'decode', 'a = { b = 1, }\n')
add('hand_err_table_twice', 'decode', '[a]\nx = 1\n[a]\ny = 2\n')
add('hand_err_dotted_then_header', 'decode', 'a.b = 1\n[a]\n')
add('hand_err_header_then_dotted', 'decode', '[a.b]\nc = 1\n[a]\nb.d = 2\n')
add('hand_err_extend_inline', 'decode', 'a = { b = 1 }\n[a.c]\nx = 1\n')
add('hand_err_aot_over_table', 'decode', '[[a.b]]\nx = 1\n[[a]]\ny = 2\n')
add('hand_err_text_after_value', 'decode', 'a = 1 2\n')
add('hand_err_nonascii_digit_date', 'decode', 'a = \u0661\u0669\u0667\u0669-\u0660\u0665-\u0662\u0667\n')
add('hand_err_nonascii_digit_time', 'decode', 'a = \u0660\u0667:\u0663\u0662:\u0660\u0660\n')
add('hand_err_nonascii_digit_fraction', 'decode', 'a = 1979-05-27T07:32:00.\u0661\n')
add('hand_err_nonascii_digit_offset', 'decode',
    'a = 1979-05-27T07:32:00+\u0660\u0660:\u0660\u0660\n')

# ---------------------------------------------------------------------------
# Hand-written encode cases
# ---------------------------------------------------------------------------

def tag(kind, text):
    return {'type': kind, 'value': text}


def enc(name, doc):
    add('encode_' + name, 'encode',
        json.dumps(doc, ensure_ascii=False, sort_keys=True, separators=(',', ':')))


enc('empty', {})
enc('scalars', {
    's': tag('string', 'hello'), 'i': tag('integer', '-42'),
    'f': tag('float', ref.format_float(3.5)), 'b': tag('bool', 'false'),
    'odt': tag('datetime', '1979-05-27T07:32:00Z'),
    'ldt': tag('datetime-local', '1979-05-27T07:32:00.5'),
    'ld': tag('date-local', '1979-05-27'), 'lt': tag('time-local', '07:32:00'),
})
enc('key_quoting', {
    'bare-key_9': tag('integer', '1'), '': tag('integer', '2'),
    'has space': tag('integer', '3'), 'has.dot': tag('integer', '4'),
    '\u00e9t\u00e9': tag('integer', '5'), 'quote"': tag('integer', '6'),
    'back\\slash': tag('integer', '7'),
})
enc('string_escapes', {
    'a': tag('string', '\b\t\n\f\r"\\'),
    'b': tag('string', 'control \x00\x01\x1f\x7f end'),
    'c': tag('string', '\u00e9\u4e2d\U0001F600'),
    'd': tag('string', ''),
})
enc('float_forms', {
    'inf': tag('float', 'inf'), 'ninf': tag('float', '-inf'),
    'nan': tag('float', 'nan'), 'zero': tag('float', ref.format_float(0.0)),
    'nzero': tag('float', ref.format_float(-0.0)),
    'pi': tag('float', ref.format_float(3.141592653589793)),
    'tiny': tag('float', ref.format_float(5e-324)),
    'huge': tag('float', ref.format_float(1.7976931348623157e308)),
})
enc('nested_tables', {
    'z': tag('integer', '1'),
    'a': {'b': {'c': {'d': tag('string', 'deep')}}, 'x': tag('integer', '2')},
    'm': {},
})
enc('empty_containers', {
    'arr': [], 'tbl': {}, 'arr_of_arr': [[], []],
    'deep': {'inner': {}},
})
enc('array_of_tables', {
    'products': [
        {'name': tag('string', 'Hammer'), 'sku': tag('integer', '738594937')},
        {},
        {'name': tag('string', 'Nail'), 'variants': [{'color': tag('string', 'red')}]},
    ],
})
enc('mixed_arrays', {
    'a': [tag('integer', '1'), tag('string', 'two'), [tag('bool', 'true')]],
    'b': [{'x': tag('integer', '1')}, tag('integer', '2')],
    'c': [[{'x': tag('integer', '1')}]],
    'd': [{'k': {'j': tag('integer', '1')}, 'e': []}],
})
enc('ordering', {
    'zz': tag('integer', '1'), 'table': {'inner': tag('integer', '2')},
    'aa': tag('integer', '3'), 'Table': {'inner': tag('integer', '4')},
    'ZZ': tag('integer', '5'), '0': tag('integer', '6'),
})
enc('quoted_paths', {
    'dog': {'tater.man': {'type': {'name': tag('string', 'pug')}}},
    '': {'': {'': tag('integer', '1')}},
})
enc('datetimes', {
    'a': tag('datetime', '0001-01-01T00:00:00Z'),
    'b': tag('datetime', '9999-12-31T23:59:59.999999+13:00'),
    'c': tag('datetime-local', '2024-02-29T15:15:15'),
    'd': tag('date-local', '2024-02-29'),
    'e': tag('time-local', '00:00:00.1'),
})
enc('aot_nested', {
    'fruits': [
        {'name': tag('string', 'apple'),
         'physical': {'color': tag('string', 'red')},
         'varieties': [{'name': tag('string', 'red delicious')},
                       {'name': tag('string', 'granny smith')}]},
        {'name': tag('string', 'banana'),
         'varieties': [{'name': tag('string', 'plantain')}]},
    ],
})
enc('type_value_keys', {
    'type': tag('string', 'string'), 'value': tag('string', '1'),
    'inner': {'type': tag('string', 'x'), 'value': tag('string', 'y')},
})
enc('key_order_codepoint', {
    'a': tag('integer', '1'), '\ue000': tag('integer', '2'),
    '\ufffd': tag('integer', '3'), '\U00010000': tag('integer', '4'),
    '\U0001f600': tag('integer', '5'),
    't': {'inline': {'\U0001f600': tag('integer', '1'),
                     '\ufffd': tag('integer', '2'),
                     '\ue000': tag('integer', '3')},
          '\U0001f600': {'x': tag('integer', '6')},
          '\ufffd': {'x': tag('integer', '7')}},
})

# Encode input need not be sorted or compact; only its tree matters.
add('encode_unsorted_input', 'encode',
    '{\n  "zebra" : { "inner" : { "type": "integer", "value": "2" } },\n'
    '  "alpha" : {\n    "value" : "1",\n    "type" : "integer"\n  },\n'
    '  "mid" : [ { "b" : { "type" : "bool", "value" : "true" } } ]\n}\n')


# ---------------------------------------------------------------------------
# toml-test corpus
# ---------------------------------------------------------------------------

def suite_files():
    with open(os.path.join(SUITE, 'files-toml-1.0.0')) as f:
        names = [line.strip() for line in f if line.strip()]
    valid = sorted(n for n in names if n.startswith('valid/') and n.endswith('.toml'))
    invalid = sorted(n for n in names if n.startswith('invalid/') and n.endswith('.toml'))
    return valid, invalid


def suite_name(path):
    return path[:-5].replace('/', '_').replace('-', '_').replace('.', '_')


SUITE_VALID, SUITE_INVALID = suite_files()

for path in SUITE_VALID:
    with open(os.path.join(SUITE, path), 'rb') as f:
        add(suite_name(path), 'decode', f.read())
for path in SUITE_INVALID:
    with open(os.path.join(SUITE, path), 'rb') as f:
        add(suite_name(path), 'decode', f.read())

# A spread of suite documents re-encoded from their tagged JSON.
ENCODE_FROM_SUITE = [
    'valid/array/array.toml', 'valid/array/empty.toml',
    'valid/array/hetergeneous.toml', 'valid/array/nested-inline-table.toml',
    'valid/array/table-array-string-backslash.toml',
    'valid/bool/bool.toml', 'valid/comment/everywhere.toml',
    'valid/datetime/datetime.toml', 'valid/datetime/edge.toml',
    'valid/datetime/local.toml', 'valid/datetime/milliseconds.toml',
    'valid/datetime/timezone.toml', 'valid/example.toml',
    'valid/float/exponent.toml', 'valid/float/float.toml',
    'valid/float/inf-and-nan.toml', 'valid/float/zero.toml',
    'valid/implicit-and-explicit-after.toml',
    'valid/inline-table/array-01.toml', 'valid/inline-table/key-dotted-01.toml',
    'valid/inline-table/nest.toml', 'valid/integer/integer.toml',
    'valid/integer/literals.toml', 'valid/integer/long.toml',
    'valid/key/alphanum.toml', 'valid/key/empty-01.toml',
    'valid/key/escapes.toml', 'valid/key/quoted-unicode.toml',
    'valid/key/space.toml', 'valid/multibyte.toml',
    'valid/spec-1.0.0/array-of-tables-0.toml',
    'valid/spec-1.0.0/table-7.toml',
    'valid/string/escapes.toml', 'valid/string/multiline.toml',
    'valid/string/multiline-quotes.toml', 'valid/string/raw.toml',
    'valid/string/with-pound.toml',
    'valid/table/array-nest.toml', 'valid/table/sub-empty.toml',
    'valid/table/without-super.toml',
]


# ---------------------------------------------------------------------------
# Real-world files and a large generated document
# ---------------------------------------------------------------------------

REAL_FILES = ['serde-Cargo.toml', 'ripgrep-Cargo.toml', 'tokio-Cargo.toml',
              'black-pyproject.toml', 'rust-Cargo.toml', 'ruff-pyproject.toml',
              'pydantic-pyproject.toml', 'ripgrep-Cargo.lock', 'uv-Cargo.lock']
ENCODE_REAL = ['serde-Cargo.toml', 'black-pyproject.toml', 'ripgrep-Cargo.lock',
               'uv-Cargo.lock']

WORDS = ['alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf',
         'hotel', 'india', 'juliett', 'kilo', 'lima', 'mike', 'november',
         'oscar', 'papa', 'quebec', 'romeo', 'sierra', 'tango']


def build_large(rng, packages):
    """Builds a lock-file shaped TOML document of a predictable size."""
    out = ['# Generated index; do not edit by hand.', 'version = 3', '']
    for n in range(packages):
        name = '%s-%s-%d' % (rng.choice(WORDS), rng.choice(WORDS), n)
        out.append('[[package]]')
        out.append('name = "%s"' % name)
        out.append('version = "%d.%d.%d"' % (rng.randrange(20), rng.randrange(40),
                                             rng.randrange(100)))
        out.append('source = "registry+https://example.invalid/index"')
        out.append('checksum = "%040x"' % rng.getrandbits(160))
        out.append('published = %04d-%02d-%02dT%02d:%02d:%02dZ'
                   % (2000 + rng.randrange(25), rng.randrange(1, 13),
                      rng.randrange(1, 29), rng.randrange(24), rng.randrange(60),
                      rng.randrange(60)))
        out.append('weight = %d.%d' % (rng.randrange(1000), rng.randrange(1000000)))
        out.append('yanked = %s' % ('true' if rng.randrange(8) == 0 else 'false'))
        deps = [rng.choice(WORDS) + '-' + rng.choice(WORDS)
                for _ in range(rng.randrange(6))]
        out.append('dependencies = [%s]' % ', '.join('"%s"' % d for d in deps))
        out.append('features = { default = [%s], extra = %s }'
                   % (', '.join('"%s"' % rng.choice(WORDS) for _ in range(2)),
                      'true' if rng.randrange(2) else 'false'))
        out.append('description = """')
        out.append('%s %s, %s.' % (rng.choice(WORDS), rng.choice(WORDS),
                                   rng.choice(WORDS)))
        out.append('Unicode: \u00e9\u4e2d\u2603 \\u00e9 tab:\\t quote:\\" done."""')
        out.append("notes = 'raw \\d{2} literal'")
        out.append('')
        out.append('[package.metadata]')
        out.append('rank = 0x%x' % rng.getrandbits(24))
        out.append('ratio = %de-%d' % (rng.randrange(1, 10000), rng.randrange(1, 12)))
        out.append('tags.primary = "%s"' % rng.choice(WORDS))
        out.append('tags.secondary = "%s"' % rng.choice(WORDS))
        out.append('')
    return '\n'.join(out)


# ---------------------------------------------------------------------------
# Oracles
# ---------------------------------------------------------------------------

def tagged_from_tomllib(v):
    """Converts a tomllib result into the reference's tagged-JSON shape."""
    if isinstance(v, dict):
        return {k: tagged_from_tomllib(x) for k, x in v.items()}
    if isinstance(v, list):
        return [tagged_from_tomllib(x) for x in v]
    if isinstance(v, bool):
        return {'type': 'bool', 'value': 'true' if v else 'false'}
    if isinstance(v, int):
        return {'type': 'integer', 'value': str(v)}
    if isinstance(v, float):
        return {'type': 'float', 'value': ref.format_float(v)}
    if isinstance(v, str):
        return {'type': 'string', 'value': v}
    if isinstance(v, datetime.datetime):
        kind = 'datetime' if v.tzinfo is not None else 'datetime-local'
        text = '%04d-%02d-%02dT%02d:%02d:%02d' % (v.year, v.month, v.day,
                                                  v.hour, v.minute, v.second)
        text += fraction(v.microsecond)
        if v.tzinfo is not None:
            secs = int(v.utcoffset().total_seconds())
            if secs == 0:
                text += 'Z'
            else:
                sign = '+' if secs > 0 else '-'
                secs = abs(secs)
                text += '%s%02d:%02d' % (sign, secs // 3600, (secs % 3600) // 60)
        return {'type': kind, 'value': text}
    if isinstance(v, datetime.date):
        return {'type': 'date-local', 'value': '%04d-%02d-%02d' % (v.year, v.month, v.day)}
    if isinstance(v, datetime.time):
        return {'type': 'time-local',
                'value': '%02d:%02d:%02d%s' % (v.hour, v.minute, v.second,
                                               fraction(v.microsecond))}
    raise AssertionError('unexpected tomllib value %r' % (v,))


def fraction(microsecond):
    if not microsecond:
        return ''
    return ('.%06d' % microsecond).rstrip('0')


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':'))


def suite_expected(path):
    """Reads the suite's .json file and normalises it to canonical text."""
    with open(os.path.join(SUITE, path[:-5] + '.json'), encoding='utf-8') as f:
        return canonical_json(normalise_suite(json.load(f)))


def normalise_suite(v):
    if isinstance(v, list):
        return [normalise_suite(x) for x in v]
    if set(v) == {'type', 'value'} and isinstance(v.get('value'), str):
        kind, text = v['type'], v['value']
        if kind == 'float':
            return {'type': kind, 'value': ref.format_float(float(text))}
        if kind in ('datetime', 'datetime-local', 'date-local', 'time-local'):
            return {'type': kind, 'value': normalise_suite_datetime(text)}
        return {'type': kind, 'value': text}
    return {k: normalise_suite(x) for k, x in v.items()}


def normalise_suite_datetime(text):
    """Puts a suite datetime into the canonical form SPEC.md defines."""
    text = text.replace('t', 'T').replace('z', 'Z')
    offset = ''
    if text.endswith('Z'):
        text, offset = text[:-1], 'Z'
    elif len(text) > 6 and text[-6] in '+-' and text[-3] == ':':
        text, offset = text[:-6], text[-6:]
        if offset[1:] == '00:00':
            offset = 'Z'
    if '.' in text:
        head, frac = text.split('.')
        frac = frac.rstrip('0')
        text = head + ('.' + frac if frac else '')
    return text + offset


def run_reference(mode, body):
    data = mode.encode('ascii') + b'\n' + body
    proc = subprocess.run([sys.executable, REF], input=data,
                          capture_output=True, timeout=600)
    if proc.returncode != 0:
        raise AssertionError('reference failed: %s' % proc.stderr.decode()[:400])
    return proc.stdout.decode('utf-8')


def fail(name, message):
    print('MISMATCH in %s: %s' % (name, message))
    sys.exit(1)


def check_decode(name, body, output, oracle):
    """Compares a decode result with tomllib."""
    text = output.rstrip('\n')
    try:
        parsed = tomllib.loads(body.decode('utf-8'))
    except Exception:
        parsed = None
    if text == 'error':
        if parsed is not None and oracle:
            fail(name, 'reference rejected a document tomllib accepts')
        return
    if parsed is None:
        if oracle:
            fail(name, 'reference accepted a document tomllib rejects')
        return
    expected = canonical_json(tagged_from_tomllib(parsed))
    if oracle and expected != text:
        fail(name, 'tomllib disagrees\n  ref %s\n  lib %s' % (text[:400], expected[:400]))


def check_encode(name, body, output):
    """Requires decode(encode(x)) == x and tomllib agreement on the output."""
    original = canonical_json(json.loads(body.decode('utf-8')))
    back = run_reference('decode', output.encode('utf-8')).rstrip('\n')
    if back != original:
        fail(name, 'round trip differs\n  in  %s\n  out %s' % (original[:400], back[:400]))
    try:
        parsed = tomllib.loads(output)
    except Exception as exc:
        fail(name, 'tomllib rejected the canonical TOML: %s' % exc)
    expected = canonical_json(tagged_from_tomllib(parsed))
    if expected != original:
        fail(name, 'tomllib disagrees with the encoded document\n  in  %s\n  lib %s'
             % (original[:400], expected[:400]))


def main():
    # Suite cases re-encoded from their decoded JSON.
    for path in ENCODE_FROM_SUITE:
        with open(os.path.join(SUITE, path), 'rb') as f:
            tagged = run_reference('decode', f.read()).rstrip('\n')
        assert tagged != 'error', path
        add('encode_' + suite_name(path), 'encode', tagged)

    # Real-world documents.
    for name in REAL_FILES:
        with open(os.path.join(REAL, name), 'rb') as f:
            body = f.read()
        add('real_' + name.replace('-', '_').replace('.', '_'), 'decode', body)
    for name in ENCODE_REAL:
        with open(os.path.join(REAL, name), 'rb') as f:
            tagged = run_reference('decode', f.read()).rstrip('\n')
        add('real_encode_' + name.replace('-', '_').replace('.', '_'), 'encode', tagged)

    # A large generated document, decoded and re-encoded.
    large = build_large(random.Random(20240921), 4000)
    add('large_generated', 'decode', large)
    add('large_generated_encode', 'encode', run_reference('decode', large.encode('utf-8')).rstrip('\n'))

    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith('.in') or f.endswith('.out'):
            os.remove(os.path.join(TESTS, f))

    assert len(cases) < 1000, 'test numbering assumes fewer than 1000 cases'
    seen = set()
    suite_index = {name: path for name, path in
                   ((suite_name(p), p) for p in SUITE_VALID)}
    for index, (name, mode, body, oracle) in enumerate(cases, 1):
        assert name not in seen, name
        seen.add(name)
        base = '%03d_%s' % (index, name)
        output = run_reference(mode, body)
        if mode == 'decode':
            check_decode(name, body, output, oracle)
            if name in suite_index:
                expected = suite_expected(suite_index[name])
                if output.rstrip('\n') != expected:
                    fail(name, 'toml-test JSON disagrees\n  ref %s\n  suite %s'
                         % (output[:400], expected[:400]))
        else:
            check_encode(name, body, output)
        with open(os.path.join(TESTS, base + '.in'), 'wb') as f:
            f.write(mode.encode('ascii') + b'\n' + body)
        with open(os.path.join(TESTS, base + '.out'), 'w', encoding='utf-8') as f:
            f.write(output)
    print('%d tests written' % len(cases))


# tests/ is handed out without corpus/, so it carries the licences of its
# third-party data.
TEST_NOTICE = 'corpus/tests-notice.md'
TEST_LICENCES = [
    ('corpus/toml-test/LICENSE',
     'LICENSE-toml-test.txt'),
    ('corpus/real-world/LICENSE-black-MIT',
     'LICENSE-black-MIT.txt'),
    ('corpus/real-world/LICENSE-cargo-MIT',
     'LICENSE-cargo-MIT.txt'),
    ('corpus/real-world/LICENSE-pydantic-MIT',
     'LICENSE-pydantic-MIT.txt'),
    ('corpus/real-world/LICENSE-ripgrep-MIT',
     'LICENSE-ripgrep-MIT.txt'),
    ('corpus/real-world/LICENSE-ruff-MIT',
     'LICENSE-ruff-MIT.txt'),
    ('corpus/real-world/LICENSE-serde-MIT',
     'LICENSE-serde-MIT.txt'),
    ('corpus/real-world/LICENSE-tokio-MIT',
     'LICENSE-tokio-MIT.txt'),
    ('corpus/real-world/LICENSE-uv-MIT',
     'LICENSE-uv-MIT.txt'),
]


def copy_licences():
    shutil.copyfile(os.path.join(HERE, TEST_NOTICE),
                    os.path.join(TESTS, 'THIRD_PARTY.md'))
    for src, name in TEST_LICENCES:
        shutil.copyfile(os.path.join(HERE, src), os.path.join(TESTS, name))


if __name__ == '__main__':
    main()
    copy_licences()
