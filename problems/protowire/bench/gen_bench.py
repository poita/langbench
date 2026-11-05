#!/usr/bin/env python3
"""Generates the protowire performance benchmark inputs in bench/.

The layout matches tests/ (NNN_name.in / NNN_name.out) so that
`run_tests.py protowire --tests-dir problems/protowire/bench` works. Every
input is produced by a seeded generator, and its expected output comes from
reference/main.py. Each input stays within SPEC.md's limits: total input under
6 MB, single payloads of at most about 0.6 MB, at most 100,000 repeated
elements per message, nesting depth at most 64, schemas of at most 50 messages
with at most 64 fields each.

Pass --oracle to also cross-check every request against protoc + the protobuf
runtime, using the same oracle as gen_tests.py.
"""
import argparse
import os
import random
import subprocess
import sys
import tempfile
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
REF = os.path.join(PROBLEM, 'reference', 'main.py')
sys.path.insert(0, PROBLEM)
import gen_tests as G  # noqa: E402  (helpers: wire writer, renderer, random schemas)

# Inputs stay under SPEC.md's "total input under 6 MB"; 5 MB each keeps bench/ under 30 MB.
BUDGET = 5_000_000
MAX_PAYLOAD = 600_000

WORDS = ['request', 'served', 'cache', 'miss', 'hit', 'user', 'login', 'timeout', 'retry', 'ok',
         'upstream', 'latency', 'GET', 'POST', '/api/v1/items', 'shard', 'replica', 'commit',
         'rollback', 'queue', 'drained', 'café', 'naïve', 'Zürich', '東京', 'данные', '✓', '🚀']
HOSTS = ['web-%02d.eu-west' % i for i in range(24)] + ['db-%d.us-east' % i for i in range(8)]
KEYS = ['user_id', 'path', 'status', 'region', 'build', 'session', 'bytes', 'agent', 'error', 'tenant']


def sentence(rng, lo, hi):
    s = ' '.join(rng.choice(WORDS) for _ in range(rng.randint(lo, hi)))
    r = rng.random()
    if r < 0.05:
        s += '\t"quoted"'
    elif r < 0.08:
        s += '\nC:\\path\\to\\file'
    return s


# ---------------------------------------------------------------------------
# 001: bulk decode of telemetry batches.
# ---------------------------------------------------------------------------
TELEMETRY_SCHEMA = '''
message Batch {
  repeated Event events = 1;
  string source = 2;
  uint64 seq = 3;
  Header header = 4;
}
message Header {
  int64 ts = 1;
  string host = 2;
  repeated string labels = 3;
  fixed64 trace_hi = 4;
  fixed64 trace_lo = 5;
}
message Event {
  uint64 id = 1;
  int64 ts = 2;
  string name = 3;
  repeated sint64 deltas = 4;
  repeated fixed32 samples = 5;
  repeated Attr attrs = 6;
  bytes payload = 7;
  bool ok = 8;
  sint32 level = 9;
  Header ctx = 10;
  int32 code = 11;
  repeated uint32 counts = 12;
  Marker marker = 13;
}
message Marker { sfixed64 when = 1; sfixed32 delta = 2; }
message Attr {
  string key = 1;
  string str = 2;
  int64 num = 3;
  bytes raw = 4;
  bool flag = 5;
}
'''

TELEMETRY = {
    'Batch': [('events', 'Event', 1, True), ('source', 'string', 2, False), ('seq', 'uint64', 3, False),
              ('header', 'Header', 4, False)],
    'Header': [('ts', 'int64', 1, False), ('host', 'string', 2, False), ('labels', 'string', 3, True),
               ('trace_hi', 'fixed64', 4, False), ('trace_lo', 'fixed64', 5, False)],
    'Event': [('id', 'uint64', 1, False), ('ts', 'int64', 2, False), ('name', 'string', 3, False),
              ('deltas', 'sint64', 4, True), ('samples', 'fixed32', 5, True), ('attrs', 'Attr', 6, True),
              ('payload', 'bytes', 7, False), ('ok', 'bool', 8, False), ('level', 'sint32', 9, False),
              ('ctx', 'Header', 10, False), ('code', 'int32', 11, False), ('counts', 'uint32', 12, True),
              ('marker', 'Marker', 13, False)],
    'Marker': [('when', 'sfixed64', 1, False), ('delta', 'sfixed32', 2, False)],
    'Attr': [('key', 'string', 1, False), ('str', 'string', 2, False), ('num', 'int64', 3, False),
             ('raw', 'bytes', 4, False), ('flag', 'bool', 5, False)],
}


def drop_defaults(pairs):
    """Removes fields holding their default value so the canonical text matches the decoded form."""
    out = []
    for k, v in pairs:
        if isinstance(v, tuple):
            out.append((k, drop_defaults(v)))
        elif isinstance(v, list):
            if v:
                out.append((k, [drop_defaults(x) if isinstance(x, tuple) else x for x in v]))
        elif v not in (0, "", b"", False):
            out.append((k, v))
    return tuple(out)


def tele_header(rng, ts):
    h = [('ts', ts), ('host', rng.choice(HOSTS))]
    if rng.random() < 0.7:
        h.append(('labels', [rng.choice(['prod', 'canary', 'blue', 'green', 'v2', 'eu', 'us']) for _ in range(rng.randint(1, 4))]))
    if rng.random() < 0.6:
        h.append(('trace_hi', rng.getrandbits(64)))
        h.append(('trace_lo', rng.getrandbits(64)))
    return tuple(h)


def tele_event(rng, i, ts):
    ev = [('id', 1_000_000_000 + i * 7 + rng.randint(0, 6)), ('ts', ts), ('name', sentence(rng, 1, 4))]
    n = rng.choice([0, 0, 2, 5, 12, 40])
    if n:
        ev.append(('deltas', [rng.randint(-5000, 5000) if rng.random() < 0.9 else rng.randint(-2 ** 63, 2 ** 63 - 1)
                              for _ in range(n)]))
    n = rng.choice([0, 4, 16, 64])
    if n:
        ev.append(('samples', [rng.getrandbits(32) for _ in range(n)]))
    attrs = []
    for _ in range(rng.randint(0, 6)):
        a = [('key', rng.choice(KEYS))]
        r = rng.random()
        if r < 0.5:
            a.append(('str', sentence(rng, 1, 3)))
        elif r < 0.8:
            a.append(('num', rng.randint(-10 ** 6, 10 ** 12)))
        elif r < 0.9:
            a.append(('raw', bytes(rng.getrandbits(8) for _ in range(rng.randint(1, 24)))))
        else:
            a.append(('flag', True))
        attrs.append(tuple(a))
    if attrs:
        ev.append(('attrs', attrs))
    if rng.random() < 0.3:
        ev.append(('payload', bytes(rng.getrandbits(8) for _ in range(rng.randint(8, 96)))))
    ev.append(('ok', rng.random() < 0.9))
    ev.append(('level', rng.randint(-3, 6)))
    if rng.random() < 0.25:
        ev.append(('ctx', tele_header(rng, ts - rng.randint(0, 10 ** 6))))
    ev.append(('code', rng.choice([0, 200, 200, 200, 204, 301, 404, 500, -1])))
    if rng.random() < 0.4:
        ev.append(('counts', [rng.randint(0, 100000) for _ in range(rng.randint(1, 20))]))
    if rng.random() < 0.15:
        ev.append(('marker', (('when', rng.randint(-2 ** 63, 2 ** 63 - 1)), ('delta', rng.randint(-2 ** 31, 2 ** 31 - 1)))))
    return drop_defaults(ev)


def tele_batch(rng, n_events, seq):
    ts = 1_700_000_000_000_000 + seq * 1_000_003
    events = [tele_event(rng, seq * 100_000 + i, ts + i * 977) for i in range(n_events)]
    return drop_defaults([('events', events), ('source', rng.choice(HOSTS)), ('seq', seq),
                          ('header', tele_header(rng, ts))])


def gen_decode_throughput(seed):
    rng = random.Random(seed)
    reqs = []
    total = 0
    seq = 1
    while True:
        r = rng.random()
        if seq % 30 == 0:
            n_events = rng.randint(1500, 2000)   # periodic large batch (~0.4-0.55 MB)
        elif r < 0.25:
            n_events = rng.randint(100, 400)
        else:
            n_events = rng.randint(5, 60)
        batch = tele_batch(rng, n_events, seq)
        data = G.encode_value(rng, TELEMETRY, 'Batch', batch, noise=0.02, unpacked=0.05, nonminimal=0.01)
        if rng.random() < 0.1:
            # Two concatenated batches: a valid stream that merges `header` and appends `events`.
            extra = tele_batch(rng, rng.randint(2, 20), seq)
            data += G.encode_value(rng, TELEMETRY, 'Batch', extra)
        if len(data) > MAX_PAYLOAD:
            continue
        if rng.random() < 0.01:
            data = data[:rng.randint(1, len(data) - 1)]  # truncated in transit: `error`
        line = G.dec('Batch', data)
        if total + len(line) + 1 > BUDGET:
            break
        reqs.append(line)
        total += len(line) + 1
        seq += 1
    return TELEMETRY_SCHEMA, reqs


# ---------------------------------------------------------------------------
# 002: bulk encode of syntax trees from text (deep nesting, length prefixes).
# ---------------------------------------------------------------------------
AST_SCHEMA = '''
message Module { string path = 1; repeated Node decls = 2; repeated string imports = 3; Pos end = 4; bytes digest = 5; }
message Pos { uint32 line = 1; uint32 col = 2; uint32 offset = 3; }
message Node {
  string kind = 1;
  Pos pos = 2;
  repeated Node kids = 3;
  string ident = 4;
  int64 ival = 5;
  string sval = 6;
  repeated sint32 dims = 7;
  bool is_const = 8;
  fixed64 hash = 9;
  Node type = 10;
  repeated uint64 refs = 11;
  bytes blob = 12;
}
'''

KINDS_LEAF = ['Ident', 'IntLit', 'StrLit', 'BoolLit']
KINDS_INNER = ['Call', 'BinOp', 'Block', 'If', 'While', 'Return', 'Assign', 'Index', 'Field', 'Lambda']
IDENTS = ['x', 'y', 'idx', 'count', 'buffer', 'result', 'self', 'node', 'parent', 'value', 'len', 'i', 'j',
          'données', 'größe', 'π']


def ast_pos(rng, line):
    return (('line', line), ('col', rng.randint(1, 120)), ('offset', line * 40 + rng.randint(0, 39)))


def ast_node(rng, depth, budget, line, max_depth):
    """A random syntax-tree node; `budget` is the rough number of descendants still allowed."""
    if depth >= max_depth or budget[0] <= 0 or (depth > 2 and rng.random() < 0.3):
        kind = rng.choice(KINDS_LEAF)
    else:
        kind = rng.choice(KINDS_INNER)
    budget[0] -= 1
    n = [('kind', kind), ('pos', ast_pos(rng, line))]
    if kind == 'Ident':
        n.append(('ident', rng.choice(IDENTS)))
    elif kind == 'IntLit':
        n.append(('ival', rng.randint(-1000, 1000) if rng.random() < 0.8 else rng.randint(-2 ** 63, 2 ** 63 - 1)))
        n.append(('is_const', True))
    elif kind == 'StrLit':
        n.append(('sval', sentence(rng, 1, 5)))
    elif kind == 'BoolLit':
        n.append(('is_const', rng.random() < 0.5))
    else:
        if kind == 'Block':
            nk = rng.randint(1, 6)
        elif kind in ('BinOp', 'Assign', 'Index'):
            nk = 2
        elif kind == 'Call':
            nk = rng.randint(1, 4)
        else:
            nk = rng.randint(1, 3)
        kids = [ast_node(rng, depth + 1, budget, line + k, max_depth) for k in range(nk)]
        n.append(('kids', kids))
        if kind in ('Call', 'Field', 'Lambda'):
            n.append(('ident', rng.choice(IDENTS)))
    if rng.random() < 0.2:
        n.append(('hash', rng.getrandbits(64)))
    if rng.random() < 0.15 and depth < max_depth - 1:
        n.append(('type', (('kind', 'Type'), ('ident', rng.choice(['i32', 'u64', 'str', 'Vec<T>'])),
                           ('dims', [rng.randint(-4, 64) for _ in range(rng.randint(0, 4))]))))
    if rng.random() < 0.1:
        n.append(('refs', [rng.randint(0, 2 ** 40) for _ in range(rng.randint(1, 8))]))
    if rng.random() < 0.03:
        n.append(('blob', bytes(rng.getrandbits(8) for _ in range(rng.randint(1, 32)))))
    return drop_defaults(n)


def deep_chain(rng, depth, line):
    """A long left-nested expression chain (a + b + c + ...), depth levels of BinOp."""
    node = (('kind', 'Ident'), ('pos', ast_pos(rng, line)), ('ident', rng.choice(IDENTS)))
    for _ in range(depth - 1):
        leaf = (('kind', 'IntLit'), ('pos', ast_pos(rng, line)), ('ival', rng.randint(1, 99)), ('is_const', True))
        node = (('kind', 'BinOp'), ('pos', ast_pos(rng, line)), ('kids', [node, leaf]), ('ident', '+'))
    return node


def respace(rng, text):
    """Re-spaces a canonical text using the relaxations SPEC.md allows (spaces only outside literals)."""
    mode = rng.random()
    if mode < 0.6:
        return text
    out = []
    in_str = False
    i = 0
    while i < len(text):
        ch = text[i]
        if in_str:
            out.append(ch)
            if ch == '\\':
                out.append(text[i + 1])
                i += 1
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
            out.append(ch)
        elif ch == ' ':
            if mode < 0.8:
                pass          # compact: drop every optional space
            else:
                out.append(' ' * rng.randint(1, 3))
        else:
            out.append(ch)
            if mode >= 0.8 and ch in '{[,:' and rng.random() < 0.3:
                out.append(' ')
        i += 1
    return ''.join(out)


def shuffle_fields(rng, v):
    if isinstance(v, tuple):
        items = [(k, shuffle_fields(rng, x)) for k, x in v]
        rng.shuffle(items)
        return tuple(items)
    if isinstance(v, list):
        return [shuffle_fields(rng, x) for x in v]
    return v


def gen_encode_trees(seed):
    rng = random.Random(seed)
    reqs = []
    total = 0
    mod_id = 0
    while True:
        mod_id += 1
        decls = []
        line = 1
        n_decls = rng.choice([5, 10, 20, 40, 80])
        for _ in range(n_decls):
            if rng.random() < 0.12:
                decls.append(deep_chain(rng, rng.randint(20, 56), line))
            else:
                decls.append(ast_node(rng, 2, [rng.randint(5, 120)], line, rng.randint(8, 24)))
            line += rng.randint(3, 40)
        mod = [('path', 'src/pkg%d/mod_%d.rs' % (mod_id % 17, mod_id)), ('decls', decls),
               ('imports', ['std::%s' % rng.choice(IDENTS) for _ in range(rng.randint(0, 8))]),
               ('end', ast_pos(rng, line))]
        if rng.random() < 0.5:
            mod.append(('digest', bytes(rng.getrandbits(8) for _ in range(32))))
        value = drop_defaults(mod)
        if rng.random() < 0.2:
            value = shuffle_fields(rng, value)
        text = respace(rng, G.render(value))
        if rng.random() < 0.01:
            text = text[:-1]  # unterminated message: `error`
        line_s = 'encode Module ' + text
        if len(line_s) > 2 * MAX_PAYLOAD:
            continue
        if total + len(line_s.encode('utf-8')) + 1 > BUDGET:
            break
        reqs.append(line_s)
        total += len(line_s.encode('utf-8')) + 1
    return AST_SCHEMA, reqs


# ---------------------------------------------------------------------------
# 003: mixed request stream over a wide random schema.
# ---------------------------------------------------------------------------
def sparse_value(rng, messages, mname, depth, density):
    """Like gen_tests.rand_value, but with the field density applied at every level so that
    values over a 64-field schema stay at realistic RPC sizes."""
    pairs = []
    for fname, t, num, rep in messages[mname]:
        if rng.random() > density:
            continue
        if t in G.SCALARS:
            if rep:
                pairs.append((fname, [G.rand_scalar(rng, t) for _ in range(rng.randint(0, 6))]))
            else:
                pairs.append((fname, G.rand_scalar(rng, t)))
        elif depth < 3:
            if rep:
                pairs.append((fname, [sparse_value(rng, messages, t, depth + 1, density) for _ in range(rng.randint(0, 3))]))
            else:
                pairs.append((fname, sparse_value(rng, messages, t, depth + 1, density)))
    return tuple(pairs)


def gen_mixed_stream(seed):
    rng = random.Random(seed)
    schema, messages = G.rand_schema(rng, 50, 64)
    names = sorted(messages)
    reqs = []
    total = 0
    while True:
        mname = rng.choice(names)
        pairs = sparse_value(rng, messages, mname, 0, rng.choice([0.05, 0.1, 0.2]))
        r = rng.random()
        if r < 0.45:
            text = G.render(pairs)
            if rng.random() < 0.15:
                text = respace(rng, G.render(shuffle_fields(rng, pairs)))
            if rng.random() < 0.04 and text:
                pos = rng.randint(0, len(text) - 1)
                text = text[:pos] + rng.choice('{}[],:"x0-19 ') + text[pos:]
            line = 'encode %s %s' % (mname, text)
        else:
            data = G.encode_value(rng, messages, mname, pairs, noise=0.2, unpacked=0.3, nonminimal=0.1)
            if data and rng.random() < 0.04:
                data = data[:rng.randint(0, len(data) - 1)]
            line = G.dec(mname, data)
        size = len(line.encode('utf-8')) + 1
        if total + size > BUDGET:
            break
        reqs.append(line)
        total += size
    return schema, reqs


# Long tier (--long, written to ../bench-long): the same generators with larger
# byte budgets; SPEC.md's per-test input limit is raised to 50 MB for it.
LONG_BUDGETS = {'decode_telemetry_batches': 24_000_000, 'encode_syntax_trees': 24_000_000,
                'mixed_wide_schema_stream': 48_000_000}
LONG_LIMIT = 50_000_000

CASES = [
    ('decode_telemetry_batches', lambda: gen_decode_throughput(9001)),
    ('encode_syntax_trees', lambda: gen_encode_trees(9002)),
    ('mixed_wide_schema_stream', lambda: gen_mixed_stream(9003)),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--oracle', action='store_true', help='cross-check with protoc + protobuf runtime')
    ap.add_argument('--long', action='store_true', help='write the long tier to ../bench-long')
    args = ap.parse_args()
    global BUDGET
    out_dir = os.path.join(PROBLEM, 'bench-long') if args.long else HERE
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith('.in') or f.endswith('.out'):
            os.remove(os.path.join(out_dir, f))
    workdir = tempfile.mkdtemp(prefix='protowire_bench_oracle_')
    try:
        for idx, (name, fn) in enumerate(CASES, 1):
            if args.long:
                BUDGET = LONG_BUDGETS[name]
            schema, reqs = fn()
            text = schema.strip('\n') + '\n--\n' + '\n'.join(reqs) + '\n'
            data = text.encode('utf-8')
            assert len(data) < (LONG_LIMIT if args.long else 6_000_000), (name, len(data))
            out = subprocess.run([sys.executable, REF], input=data, capture_output=True, check=True,
                                 timeout=2700 if args.long else 600).stdout
            base = '%03d_%s' % (idx, name)
            in_path = os.path.join(out_dir, base + '.in')
            out_path = os.path.join(out_dir, base + '.out')
            with open(in_path, 'wb') as f:
                f.write(data)
            with open(out_path, 'wb') as f:
                f.write(out)
            n_err = out.count(b'error\n')
            print('%-32s %9d bytes in, %9d bytes out, %6d requests, %5d errors'
                  % (base, len(data), len(out), len(reqs), n_err))
            if args.oracle:
                G.oracle_check(100 + idx, text, in_path, out_path, workdir)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == '__main__':
    main()
