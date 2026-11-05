#!/usr/bin/env python3
"""Generates the jq performance benchmark inputs in bench/ (same layout as tests/).

Documents come from gen_tests.gen_records with fixed seeds, so re-running this
script reproduces the benchmark exactly. Expected outputs come from
reference/main.py and are cross-checked against the real jq binary (jq 1.7.x)
and against the SPEC.md number-printing restrictions, exactly as gen_tests.py
does for the public tests.

Usage: gen_bench.py [--inputs-only] [--long]

--long writes the long tier to ../bench-long/: the same document and the same
three filters, each made to do more evaluation work over it (see NOTES.md).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import gen_tests  # noqa: E402  (importing only builds the public case list)

MAX_DOC = 6_000_000

# Largest record count whose compact document stays under the 6 MB limit.
RECORDS = gen_tests.gen_records(101, 28500)
DOC = gen_tests.compact(RECORDS)
assert len(DOC.encode('utf-8')) <= MAX_DOC, len(DOC.encode('utf-8'))

# 1. Streaming per-record transformation: every record is visited and most
#    produce a reshaped output object, so parse + evaluate + print throughput
#    over a full-size document dominates.
STREAM = (
    '. as $all | .[] | select(.address.city != "Rome" and .age >= 20) | '
    '{id, name, dept: (if .dept == null then "none" else .dept end), city: .address.city, '
    'region: .address.zip[0:2], lat: .address.geo[0], lvl: .manager.level?, '
    'mgr: (if .manager then . as $e | $all[.manager.id] | {name, city: .address.city, same: (.dept == $e.dept)} else null end), '
    'tagstr: (.tags | sort | reduce .[] as $t (""; . + $t + ",")), '
    'dist: (.address.geo | (if .[0] < 0 then -.[0] else .[0] end) + (if .[1] < 0 then -.[1] else .[1] end)), '
    'tags: (.tags | sort | reverse), ntags: (.tags | length), '
    'senior: (.age > 50 and .score > 70), key: (.name + "@" + .address.city), '
    'band: (.score - .score % 10), first: ((.name / "_") | .[0]), '
    'rich: (if .balance > 4000 then "high" elif .balance > 1000 then "mid" else "low" end), '
    'flags: [(.tags[] | select(. == "vip" or . == "gold")), (if .active then "active" else empty end)]}'
)

# 2. Sorting/grouping on full records: sort, unique, group_by, sort_by with
#    composite keys, min/max over whole objects. Comparison of arrays and
#    objects (sorted key lists, then values) is the algorithmically hardest
#    part of the language.
SORT = (
    '(sort | map(.id) | .[0:5], .[-5:]), '
    '(min | .id), (max | .id), '
    '(sort_by(.dept, .address.city, -.score, .name) | map(.id) | .[0:10], .[-10:]), '
    '(group_by(.address.city, .dept) | map([.[0].address.city, .[0].dept, length, (map(.score) | add), '
    '(map(.balance) | max), (sort_by(.age, .id) | .[0].id)])), '
    '(map(.tags) | unique | length, .[-3:]), '
    '(map(.address) | unique | length), '
    '(map(.manager) | sort | .[-3:], (unique | length)), '
    '(map([.age, .score, .name]) | sort | .[0:5]), '
    '(map({dept, city: .address.city, tags}) | unique | length), '
    '(map(.name) | sort | unique | length, .[0:3]), '
    '(sort_by(.tags, .address.geo) | map(.id) | .[0:10]), '
    '(group_by(.tags | length) | map(sort_by(.balance) | [.[0].id, .[-1].id, length]))'
)

# 3. Interpreter-heavy mixed workload: nested generators with variable
#    bindings (a self-join of a slice of records on manager id), reduce with
#    object accumulators, per-record reduce over tags, string building and
#    tostring/tonumber round-trips.
MIXED = (
    '. as $all | .[0:2000] as $s | '
    '([$s[] as $a | $s[] | select(.manager.id == $a.id and .dept == $a.dept) | [$a.id, .id]] | length, .[0:5]), '
    '(reduce .[] as $r ({}; . + {($r.address.city): (.[$r.address.city] + $r.score)})), '
    '(reduce .[] as $r ({}; . * {(if $r.dept == null then "none" else $r.dept end): {($r.address.city): '
    '((.[if $r.dept == null then "none" else $r.dept end][$r.address.city]) + 1)}})), '
    '([.[] | reduce .tags[] as $t (""; . + $t[0:1]) ] | group_by(.) | map([.[0], length]) | sort_by(-.[1], .[0]) | .[0:10]), '
    '([.[] | (.id | tostring) + ":" + (.score | tostring) | (. / ":") | map(tonumber) | add] | add), '
    '([.[] | select(.manager) | .manager.id as $m | $all[$m] | select(.active) | .address.city] | group_by(.) | map([.[0], length])), '
    '(reduce .[] as $r ([0, 0, 0]; if $r.age < 30 then [.[0] + 1, .[1], .[2]] elif $r.age < 60 then [.[0], .[1] + 1, .[2]] else [.[0], .[1], .[2] + 1] end))'
)

CASES = [
    ('large_record_stream', STREAM),
    ('sort_group_records', SORT),
    ('join_reduce_mixed', MIXED),
]

# Long tier. The document stays at the 6 MB limit; the filters repeat their
# work instead.
LONG_PASSES = 64    # 001: every pass reshapes all records, emits one id class
LONG_FOLDS = 24     # 002: one full report per leave-one-fold-out subset
LONG_SLICE = 10000   # 003: self-join slice size (quadratic inner loop)
STREAM_PREFIX = '. as $all | .[] | '


def passes(n):
    # The subset has no range/1, so a pass counter iterates a literal array.
    return '[' + ','.join(str(i) for i in range(n)) + ']'



assert STREAM.startswith(STREAM_PREFIX)
LONG_CASES = [
    ('large_record_stream',
     '. as $all | %s[] as $pass | .[] | %s | select(.id %% %d == $pass)'
     % (passes(LONG_PASSES), STREAM[len(STREAM_PREFIX):], LONG_PASSES)),
    ('sort_group_records',
     '%s[] as $fold | map(select(.id %% %d != $fold)) | %s' % (passes(LONG_FOLDS), LONG_FOLDS, SORT)),
    ('join_reduce_mixed', MIXED.replace('.[0:2000] as $s', '.[0:%d] as $s' % LONG_SLICE, 1)),
]


def run_reference_long(data):
    import subprocess
    proc = subprocess.run([sys.executable, gen_tests.REF], input=data, capture_output=True, timeout=2700)
    assert proc.returncode == 0, proc.stderr.decode()
    return proc.stdout.decode('utf-8')


def main():
    inputs_only = '--inputs-only' in sys.argv[1:]
    long_tier = '--long' in sys.argv[1:]
    out_dir = os.path.join(os.path.dirname(HERE), 'bench-long') if long_tier else HERE
    os.makedirs(out_dir, exist_ok=True)
    only = [a for a in sys.argv[1:] if not a.startswith('--')]
    for f in os.listdir(out_dir):
        if (f.endswith('.in') or f.endswith('.out')) and not only:
            os.remove(os.path.join(out_dir, f))
    for idx, (name, filt) in enumerate(LONG_CASES if long_tier else CASES, 1):
        if only and not any(o in name for o in only):
            continue
        assert '\n' not in filt and len(filt.encode('utf-8')) <= 2000, (name, len(filt))
        base = '%03d_%s' % (idx, name)
        data = (filt + '\n' + DOC + '\n').encode('utf-8')
        with open(os.path.join(out_dir, base + '.in'), 'wb') as f:
            f.write(data)
        if inputs_only:
            print('wrote %s.in (%d bytes)' % (base, len(data)))
            continue
        expected = run_reference_long(data) if long_tier else gen_tests.run_reference(data)
        oracle = gen_tests.run_jq(filt, DOC)
        if gen_tests.normalize(expected) != gen_tests.normalize(oracle):
            print('MISMATCH in %s\n  reference: %r\n  jq:        %r' % (base, expected[:400], oracle[:400]))
            sys.exit(1)
        gen_tests.check_input_numbers(filt, DOC)
        gen_tests.check_output_numbers(expected)
        with open(os.path.join(out_dir, base + '.out'), 'w', encoding='utf-8') as f:
            f.write(expected)
        print('ok %s (%d bytes in, %d lines out)' % (base, len(data), expected.count('\n')))


if __name__ == '__main__':
    main()
