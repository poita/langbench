#!/usr/bin/env python3
"""Generate the spreadsheet performance benchmark inputs deterministically.

Writes bench/NNN_name.in (same layout as tests/) and bench/NNN_name.out via
reference/main.py. Every input stays within the SPEC's stated scale: at most
about 70,000 commands and 1.3 MB of input, ranges of at most 10,000 cells,
dependency chains of at most 10,000 cells, and short, shallow formulas.
Every number the reference displays is checked to not be an exact rounding
tie at 10 significant digits, so any correctly rounded formatter agrees.
"""
import io
import os
import random
import subprocess
import sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)

from gen_tests import Gen, cn, is_rounding_tie, ref  # noqa: E402

REF = os.path.join(PROBLEM, 'reference', 'main.py')
MAX_COMMANDS = 70000
MAX_BYTES = 1_400_000

# Long tier (bench-long/): the same workbooks with many more edits, rounds or
# commands, sized so the fastest implementation needs >= 5 s. SPEC.md's scale
# note allows up to about 1,000,000 commands / 20 MB of input.
LONG = {'ledger_rollup': 40000, 'lattice_recalc_cycles': 6800,
        'random_workbook_mixed': 250000}
# The long ledger uses its own seed, one-decimal rates and a 10-row moving
# average. With two-decimal rates the running balance (~1.5 million) has four
# exact decimals, and a 12-row average gives I = E - H four decimals too, so
# over tens of thousands of gets some displayed values land on exact 10-digit
# rounding ties; with these choices both have at most 10 significant digits.
LONG_ARGS = {'ledger_rollup': (LONG['ledger_rollup'], 5111, ('1.0', '1.1', '1.2'), 10),
             'lattice_recalc_cycles': (LONG['lattice_recalc_cycles'],),
             'random_workbook_mixed': (LONG['random_workbook_mixed'],)}
LONG_MAX_COMMANDS = 1_000_000
LONG_MAX_BYTES = 20_000_000

CATEGORIES = ['rent', 'payroll', 'travel', 'software', 'hardware', 'office',
              'marketing', 'utilities', 'consulting', 'training']


def ledger_rollup(edits=1500, seed=5101, rates=None, window=12):
    """A 4,800-row transaction ledger with per-row derived columns, a running
    balance, moving averages and whole-column summaries, followed by a stream
    of edits that real users make: corrections concentrated on recent rows,
    occasional changes to the global rate and threshold inputs, category
    relabels, lookups, and a final full dump."""
    rng = random.Random(seed)
    rows = 4800
    lines = ['set K1 1.1', 'set K2 400', 'set K8 25']
    for r in range(1, rows + 1):
        lines.append('set A%d %d' % (r, 20260000 + r))
        lines.append('set B%d "%s"' % (r, rng.choice(CATEGORIES)))
        lines.append('set C%d %d.%02d' % (r, rng.randint(-300, 900), rng.randint(0, 99)))
        lines.append('set D%d =C%d*K1' % (r, r))
        lines.append('set E%d =%sD%d' % (r, 'E%d+' % (r - 1) if r > 1 else '', r))
        lines.append('set F%d =IF(D%d>K2,"large",IF(D%d<0,"refund","normal"))' % (r, r, r))
        lines.append('set G%d =B%d&"/"&F%d' % (r, r, r))
        lines.append('set H%d =AVG(C%d:C%d)' % (r, max(1, r - window + 1), r))
        lines.append('set I%d =IF(E%d<K8,"low",E%d-H%d)' % (r, r, r, r))
    lines.append('set K3 =SUM(D1:D%d)' % rows)
    lines.append('set K4 =AVG(H1:H%d)' % rows)
    lines.append('set K5 =MAX(C1:C%d)' % rows)
    lines.append('set K6 =MIN(E1:E%d)' % rows)
    lines.append('set K7 =COUNT(C1:C%d)' % rows)
    lines.append('set K9 =K3&" over "&K7&" rows, peak "&K5')
    lines.append('get K9')
    for i in range(edits):
        x = rng.random()
        if x < 0.75:
            if rng.random() < 0.8:
                r = rng.randint(rows - 400, rows)
            else:
                r = rng.randint(1, rows)
            lines.append('set C%d %d.%02d' % (r, rng.randint(-300, 900), rng.randint(0, 99)))
            lines.append('get I%d' % r)
            lines.append('get E%d' % rows)
        elif x < 0.85:
            r = rng.randint(1, rows)
            lines.append('set B%d "%s"' % (r, rng.choice(CATEGORIES)))
            lines.append('get G%d' % r)
        elif x < 0.95:
            lines.append('get %s' % cn(rng.randint(1, rows), rng.randint(1, 9)))
            lines.append('get K9')
        elif x < 0.98:
            lines.append('set K2 %d' % rng.randint(300, 700))
            lines.append('get F%d' % rng.randint(1, rows))
        else:
            if rates is None:
                lines.append('set K1 1.%02d' % rng.randint(0, 25))
            else:
                lines.append('set K1 %s' % rng.choice(rates))
            lines.append('get K3')
            lines.append('get K6')
    lines.append('dump')
    return lines


def lattice_recalc(rounds=260):
    """A 100x100 lattice where every interior cell derives from its left, upper
    and upper-left neighbours, with column totals and a grand total below it.
    Edits hit the seed corner (recalculating all ~10,000 dependants), interior
    cells (recalculating a quadrant), and close and reopen reference cycles
    that span thousands of cells, so cycle detection runs at scale."""
    rng = random.Random(5202)
    n = 100
    lines = []

    def formula(r, c):
        left, up, ul = cn(r, c - 1), cn(r - 1, c), cn(r - 1, c - 1)
        k = (r * 7 + c * 3) % 4
        if k == 0:
            return '=(%s+%s)*0.55+1' % (left, up)
        if k == 1:
            return '=MAX(%s,%s)*0.2+SUM(%s,%s,%s)*0.3+0.3' % (left, up, left, up, ul)
        if k == 2:
            return '=IF(%s>%s,%s-%s,%s-%s)*0.1+(%s+%s)*0.5+2' % (left, up, left, up, up, left, left, up)
        return '=AVG(%s,%s,%s)*1.05+0.1' % (left, up, ul)

    for c in range(1, n + 1):
        lines.append('set %s %d' % (cn(1, c), rng.randint(0, 50)))
    for r in range(2, n + 1):
        lines.append('set %s %d' % (cn(r, 1), rng.randint(0, 50)))
    for r in range(2, n + 1):
        for c in range(2, n + 1):
            lines.append('set %s %s' % (cn(r, c), formula(r, c)))
    for c in range(1, n + 1):
        lines.append('set %s =SUM(%s:%s)' % (cn(n + 1, c), cn(1, c), cn(n, c)))
    total = cn(n + 2, 1)
    corner = cn(n, n)
    lines.append('set %s =SUM(%s:%s)' % (total, cn(n + 1, 1), cn(n + 1, n)))
    lines.append('set %s ="total "&%s&", corner "&%s' % (cn(n + 2, 2), total, corner))
    lines.append('get %s' % cn(n + 2, 2))

    def probe():
        lines.append('get %s' % corner)
        lines.append('get %s' % cn(n + 2, 2))
        lines.append('get %s' % cn(rng.randint(2, n), rng.randint(2, n)))

    for i in range(rounds):
        lines.append('set A1 %d' % rng.randint(0, 99))
        probe()
        r, c = rng.randint(2, n // 2), rng.randint(2, n // 2)
        lines.append('set %s %d.3' % (cn(r, c), rng.randint(0, 99)))
        probe()
        lines.append('set %s %s' % (cn(r, c), formula(r, c)))
        probe()
        if i % 4 == 0:
            lines.append('set A1 =%s/1000' % corner)
            probe()
            lines.append('set A1 %d' % rng.randint(0, 99))
            probe()
        elif i % 4 == 2:
            r, c = rng.randint(n // 3, 2 * n // 3), rng.randint(n // 3, 2 * n // 3)
            lines.append('set %s =IF(0,%s,%s)' % (cn(r, c), corner, cn(r - 1, c)))
            probe()
            lines.append('set %s %s' % (cn(r, c), formula(r, c)))
            probe()
        if i % 30 == 29:
            lines.append('dump')
    return lines


def random_workbook(n_commands=30000):
    """A random interconnected workbook (the generator behind the public
    random tests) at the largest command count the SPEC describes: a mix of
    sets, clears, gets and occasional dumps over 640 cells, with formulas
    that use every operator, IF, and range aggregates."""
    g = Gen(random.Random(5303), 16, 40, ref_weight=0.5, func_weight=0.25)
    text = g.commands(n_commands, dump_p=0.0005, get_p=0.25, clear_p=0.05)
    return text.rstrip('\n').split('\n')


def check_ties(text, out):
    seen = []
    real = ref.format_number

    def recording(v):
        if is_rounding_tie(v):
            seen.append(v)
        return real(v)

    ref.format_number = recording
    old_in, old_out = sys.stdin, sys.stdout
    sys.stdin, sys.stdout = io.StringIO(text), io.StringIO()
    try:
        ref.main()
        inproc = sys.stdout.getvalue()
    finally:
        sys.stdin, sys.stdout = old_in, old_out
        ref.format_number = real
    if inproc != out:
        raise SystemExit('in-process output differs from subprocess')
    if seen:
        raise SystemExit('rounding ties displayed: %r' % seen[:5])


def main():
    long_tier = '--long' in sys.argv[1:]
    cases = [('ledger_rollup', ledger_rollup),
             ('lattice_recalc_cycles', lattice_recalc),
             ('random_workbook_mixed', random_workbook)]
    out_dir, max_commands, max_bytes = HERE, MAX_COMMANDS, MAX_BYTES
    if long_tier:
        out_dir = os.path.join(PROBLEM, 'bench-long')
        max_commands, max_bytes = LONG_MAX_COMMANDS, LONG_MAX_BYTES
        os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith('.in') or f.endswith('.out'):
            os.remove(os.path.join(out_dir, f))
    for i, (name, fn) in enumerate(cases, 1):
        lines = fn(*LONG_ARGS[name]) if long_tier else fn()
        text = '\n'.join(lines) + '\n'
        assert len(lines) <= max_commands, (name, len(lines))
        assert len(text.encode('utf-8')) <= max_bytes, (name, len(text))
        base = '%03d_%s' % (i, name)
        with open(os.path.join(out_dir, base + '.in'), 'w', encoding='utf-8') as f:
            f.write(text)
        proc = subprocess.run([sys.executable, REF], input=text.encode('utf-8'),
                              capture_output=True, timeout=1200)
        if proc.returncode != 0:
            raise SystemExit('reference failed on %s: %s' % (base, proc.stderr.decode()))
        out = proc.stdout.decode('utf-8')
        check_ties(text, out)
        with open(os.path.join(out_dir, base + '.out'), 'w', encoding='utf-8') as f:
            f.write(out)
        print('wrote %s (%d commands, %d bytes in, %d lines out)'
              % (base, len(lines), len(text), out.count('\n')))


if __name__ == '__main__':
    main()
