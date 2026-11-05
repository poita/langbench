#!/usr/bin/env python3
"""Generates the performance benchmark inputs for the `json` problem.

SPEC.md caps a document at 2,000,000 bytes and allows exactly one document
per input, so every benchmark input is a single document filled close to that
limit. The value generators from ../gen_tests.py are reused so the content
follows the same distribution as the test suite. Expected outputs come from
reference/main.py. Run from anywhere; output goes next to this script.
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
REF = os.path.join(PROBLEM, 'reference', 'main.py')
sys.path.insert(0, PROBLEM)

import gen_tests as g  # noqa: E402  (importing only defines cases; main() is not run)

LIMIT = 2_000_000
TARGET = 1_990_000


def fill_array(rng, make_piece, target=TARGET, sep=','):
    """Appends pieces into a top-level array until the next one would exceed target bytes."""
    out = ['[']
    size = 2
    first = True
    while True:
        piece = make_piece(rng)
        n = len(piece.encode('utf-8')) + (0 if first else len(sep))
        if size + n > target:
            break
        if not first:
            out.append(sep)
        out.append(piece)
        size += n
        first = False
    out.append(']')
    return ''.join(out)


def bench_pretty_mixed(target=TARGET, seed=101):
    """Mixed records (a quarter pretty-printed): nested arrays/objects, numbers, strings, literals, varied whitespace."""
    def piece(rng):
        chunk = []
        pretty = rng.random() < 0.25
        g.emit(rng, g.rand_value(rng, 0, 9, 6), chunk, pretty=pretty, indent=2)
        return ('\n  ' if pretty else '') + ''.join(chunk)
    return fill_array(random.Random(seed), piece, target)


TEXT_WORDS = ('the quick brown fox jumps over lazy dog error warning info request response '
              'path/to/file.json C:\\Users\\name "quoted" tab\tnewline\nunicode café naïve '
              '日本語 テキスト Ελληνικά русский 😀 🎉 𝄞 emoji€').split(' ')


def rand_text(rng, nwords):
    words = []
    for _ in range(nwords):
        if rng.random() < 0.15:
            words.append(g.rand_string(rng, 16))
        else:
            words.append(rng.choice(TEXT_WORDS))
    return ' '.join(words)


def bench_strings_unicode(target=TARGET, seed=202):
    """String-dominated log records: long messages with escapes, \\u sequences, raw multibyte UTF-8."""
    def piece(rng):
        pairs = [
            ('level', rng.choice(['debug', 'info', 'warn', 'error'])),
            ('msg', rand_text(rng, rng.randint(20, 120))),
            ('path', '/'.join(g.rand_string(rng, 8) for _ in range(rng.randint(2, 6)))),
            ('tags', [rand_text(rng, rng.randint(1, 4)) for _ in range(rng.randint(0, 5))]),
            ('raw', g.rand_string(rng, 200)),
        ]
        chunk = []
        g.emit(rng, ('obj', pairs), chunk, pretty=False)
        return ''.join(chunk)
    return fill_array(random.Random(seed), piece, target)


KEY_POOL_EXTRA = ['', 'a', 'A', 'Z', 'z', 'é', 'Ā', '\ud7ff', '\ue000', '\uffff', '😀', '\U00010000',
                  '\U0010ffff', '日本', 'key', 'Key', 'id', 'name', 'value', 'a\u0000']


def bench_objects_sort_dedup(target=TARGET, seed=303, index_scale=1):
    """Objects with many keys: large UTF-16 key sorts and last-wins deduplication at every level."""
    rng = random.Random(seed)
    # Shared vocabulary so keys collide (duplicates) and share prefixes (long comparisons).
    vocab = [g.rand_string(rng, 6) for _ in range(400)] + KEY_POOL_EXTRA

    def key(r):
        k = r.choice(vocab)
        if r.random() < 0.6:
            k += r.choice(vocab)
        if r.random() < 0.3:
            k += str(r.randint(0, 999))
        return k

    def leaf(r):
        x = r.random()
        if x < 0.5:
            return g.rand_number(r)
        if x < 0.85:
            return g.rand_string(r, 6)
        return r.choice([True, False, None])

    def obj(r, nkeys, depth):
        pairs = []
        for _ in range(nkeys):
            if depth > 0 and r.random() < 0.08:
                v = obj(r, r.randint(5, 60), depth - 1)
            else:
                v = leaf(r)
            pairs.append((key(r), v))
        return ('obj', pairs)

    def piece(r):
        chunk = []
        g.emit(r, obj(r, r.randint(200, 3000), 2), chunk, pretty=False)
        return ''.join(chunk)

    # One large ID-keyed index first (shuffled keys with long shared prefixes,
    # about 10% repeated), then many wide objects with mixed keys.
    ids = ['%s:%07d' % (rng.choice(['user', 'order', 'item']), rng.randint(0, 9_999_999))
           for _ in range(50_000 * index_scale)]
    flat_pairs = []
    for i in range(55_000 * index_scale):
        k = ids[i] if i < len(ids) else rng.choice(ids)
        flat_pairs.append((k, g.Num(str(rng.randint(0, 99999)))))
    rng.shuffle(flat_pairs)
    chunk = []
    g.emit(rng, ('obj', flat_pairs), chunk, pretty=False)
    head = ''.join(chunk)
    rest = fill_array(rng, piece, target=target - len(head.encode('utf-8')) - 1)
    return '[' + head + ',' + rest[1:]


BENCHES = [
    ('mixed_nested_records', bench_pretty_mixed),
    ('string_heavy_unicode_escapes', bench_strings_unicode),
    ('wide_objects_sort_dedup', bench_objects_sort_dedup),
]


# Long tier (../bench-long): the same three documents ten times larger
# (about 20 MB each; SPEC.md allows up to 24 MB in the long tier). JSON
# canonicalisation is linear in the input and one document is allowed per
# input, so the input size is the only lever.
LONG_DIR = os.path.join(PROBLEM, 'bench-long')
LONG_LIMIT = 24_000_000
LONG_TARGET = 19_900_000
LONG_BENCHES = [
    ('mixed_nested_records', lambda: bench_pretty_mixed(LONG_TARGET, 1101)),
    ('string_heavy_unicode_escapes', lambda: bench_strings_unicode(LONG_TARGET, 1202)),
    ('wide_objects_sort_dedup', lambda: bench_objects_sort_dedup(LONG_TARGET, 1303, 10)),
]


def main():
    sys.setrecursionlimit(20000)
    long = '--long' in sys.argv[1:]
    out_dir, limit, benches = (LONG_DIR, LONG_LIMIT, LONG_BENCHES) if long else (HERE, LIMIT, BENCHES)
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith('.in') or f.endswith('.out'):
            os.remove(os.path.join(out_dir, f))
    for idx, (name, fn) in enumerate(benches, 1):
        data = fn().encode('utf-8')
        assert len(data) <= limit, (name, len(data))
        base = '%03d_%s' % (idx, name)
        if '--no-ref' in sys.argv[1:]:
            with open(os.path.join(out_dir, base + '.in'), 'wb') as f:
                f.write(data)
            print('%-40s %9d bytes in' % (base, len(data)))
            continue
        proc = subprocess.run([sys.executable, REF], input=data, capture_output=True, timeout=3600)
        assert proc.returncode == 0, proc.stderr.decode()
        out = proc.stdout
        assert out != b'invalid\n', name
        with open(os.path.join(out_dir, base + '.in'), 'wb') as f:
            f.write(data)
        with open(os.path.join(out_dir, base + '.out'), 'wb') as f:
            f.write(out)
        expect = g.oracle(data)
        assert expect is not g.INVALID and expect is not g.UNKNOWN, name
        text = out[:-1].decode('utf-8')
        g.check_canonical_text(text)
        import json
        assert g.same(json.loads(text), expect), 'value mismatch: ' + base
        print('%-40s %9d bytes in, %9d bytes out' % (base, len(data), len(out)))


if __name__ == '__main__':
    main()
