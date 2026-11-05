#!/usr/bin/env python3
"""Generate the rrule performance benchmark inputs deterministically.

Writes bench/NNN_name.in (same layout as tests/) and bench/NNN_name.out via
reference/main.py, then cross-checks every output line against
python-dateutil (the problem's oracle) when the .oracle-venv exists. Every
input respects the SPEC limits: at most 5000 lines, N and COUNT at most
100000, and total output under 5 MB.

With --long it writes the long tier to ../bench-long instead (at most 100000
lines and 100 MB of output per input). --agree takes the expected output
from several implementations that must agree byte for byte, for inputs on
which reference/main.py is too slow.
"""
import argparse
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)

sys.dont_write_bytecode = True
import gen_tests as gt  # noqa: E402

REF = os.path.join(PROBLEM, 'reference', 'main.py')
MAX_LINES = 5000
MAX_OUT = 5_000_000
WD = gt.WD
SPARSE_RULES = 150
MIXED_SPARSE = 80


def calendar_event(rng):
    """One recurring event of the kind found in real calendars: birthdays and
    holidays (YEARLY), bills and paydays (MONTHLY), meetings (WEEKLY) and
    routines (DAILY), each with a typical end condition."""
    y = rng.randint(1950, 2030)
    m = rng.randint(1, 12)
    d = rng.randint(1, gt.ref.days_in_month(y, m))
    dt = '%04d%02d%02dT%02d%02d00' % (y, m, d, rng.choice([0, 8, 9, 10, 12, 14, 17, 19]), rng.choice([0, 15, 30, 45]))
    wd = rng.choice(WD[:5])
    kind = rng.randrange(14)
    if kind < 3:
        rule = 'FREQ=YEARLY'                                        # birthday / anniversary
    elif kind == 3:
        rule = 'FREQ=YEARLY;BYMONTH=%d;BYDAY=%d%s' % (m, rng.choice([1, 2, 3, 4, -1]), wd)   # holiday
    elif kind == 4:
        rule = 'FREQ=YEARLY;BYMONTH=%d;BYMONTHDAY=%d' % (rng.randint(1, 12), rng.randint(1, 28))
    elif kind == 5:
        rule = 'FREQ=YEARLY;BYMONTH=%s;BYMONTHDAY=-1' % ','.join(map(str, [3, 6, 9, 12]))    # quarter end
    elif kind == 6:
        rule = 'FREQ=MONTHLY;BYMONTHDAY=%s' % rng.choice(['1', '15', '-1', '1,15', '15,-1'])  # payday / bill
    elif kind == 7:
        rule = 'FREQ=MONTHLY;BYDAY=%d%s' % (rng.choice([1, 2, 3, -1]), wd)                   # n-th weekday
    elif kind == 8:
        rule = 'FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=%d' % rng.choice([1, -1])         # business day
    elif kind == 9:
        rule = 'FREQ=MONTHLY;INTERVAL=%d' % rng.choice([3, 6])
    elif kind == 10:
        rule = 'FREQ=WEEKLY;BYDAY=%s' % ','.join(sorted(rng.sample(WD[:5], rng.randint(1, 3)), key=WD.index))
    elif kind == 11:
        rule = 'FREQ=WEEKLY;INTERVAL=2;BYDAY=%s;WKST=%s' % (wd, rng.choice(['MO', 'SU']))     # sprint
    elif kind == 12:
        rule = 'FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR'                    # stand-up
    else:
        rule = 'FREQ=DAILY;INTERVAL=%d' % rng.choice([1, 2, 3])
    r = rng.random()
    if r < 0.25:
        rule += ';COUNT=%d' % rng.randint(20, 120)
    elif r < 0.5:
        rule += ';UNTIL=%04d1231T235959' % (y + rng.randint(5, 80))
    return '%s %s %d' % (dt, rule, rng.choice([45, 65, 85]))


def calendar_sync():
    """5000 ordinary calendar events expanded over multi-decade horizons, as a
    calendar server does on a bulk sync."""
    rng = random.Random(9101)
    return [calendar_event(rng) for _ in range(MAX_LINES)]


def seasonal_event(rng):
    """A calendar event confined to part of the year: public holidays written
    as DAILY rules with BYMONTH/BYMONTHDAY/BYDAY filters (as some calendar
    exporters emit them), office closure days, summer and school-term
    routines, and fiscal-year dates. Most candidate days of such a rule are
    filtered out, so each occurrence costs a scan of the off-season days."""
    y = rng.randint(1950, 2030)
    m = rng.randint(1, 12)
    d = rng.randint(1, gt.ref.days_in_month(y, m))
    dt = '%04d%02d%02dT%02d%02d00' % (y, m, d, rng.choice([0, 8, 9, 10, 12, 14, 17, 19]), rng.choice([0, 15, 30, 45]))
    wd = rng.choice(WD)
    hm = rng.randint(1, 12)
    season = sorted(rng.sample(range(1, 13), rng.randint(1, 3)))
    kind = rng.randrange(11)
    if kind < 4:                                                    # n-th / last weekday holiday
        w = rng.choice([1, 2, 3, 4, -1])
        days = range(-7, 0) if w < 0 else range(7 * w - 6, 7 * w + 1)
        rule = 'FREQ=DAILY;BYMONTH=%d;BYDAY=%s;BYMONTHDAY=%s' % (hm, wd, ','.join(map(str, days)))
    elif kind < 6:                                                  # fixed-date holiday / closure days
        days = sorted(rng.sample(range(1, 29), rng.choice([1, 1, 2, 3])))
        rule = 'FREQ=DAILY;BYMONTH=%d;BYMONTHDAY=%s' % (hm, ','.join(map(str, days)))
    elif kind == 6:                                                 # every Saturday in summer
        rule = 'FREQ=DAILY;BYMONTH=%s;BYDAY=%s' % (','.join(map(str, season)), wd)
    elif kind == 7:                                                 # seasonal weekly meeting
        rule = 'FREQ=WEEKLY;BYMONTH=%s;BYDAY=%s' % (','.join(map(str, season)), rng.choice(WD[:5]))
    elif kind == 8:                                                 # summer camp on weekdays
        rule = 'FREQ=DAILY;BYMONTH=%s;BYDAY=MO,TU,WE,TH,FR' % ','.join(map(str, season))
    elif kind == 9:                                                 # first / last business day of the year
        rule = 'FREQ=YEARLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=%d' % rng.choice([1, -1])
    else:                                                           # fiscal week
        rule = 'FREQ=YEARLY;BYWEEKNO=%s;BYDAY=%s;WKST=%s' % (
            rng.choice(['1', '13', '26', '1,27', '13,26,39,52']), rng.choice(WD[:5]), rng.choice(['MO', 'SU']))
    r = rng.random()
    if r < 0.25:
        rule += ';COUNT=%d' % rng.randint(20, 120)
    elif r < 0.5:
        rule += ';UNTIL=%04d1231T235959' % (y + rng.randint(5, 80))
    return '%s %s %d' % (dt, rule, rng.choice([45, 65, 85]))


def calendar_sync_long(count, seasonal_share):
    """A larger calendar server's bulk sync: the everyday events of
    calendar_sync plus a share of seasonal and holiday events."""
    rng = random.Random(19101)
    pick = random.Random(19102)
    return [seasonal_event(rng) if pick.random() < seasonal_share else calendar_event(rng)
            for _ in range(count)]


def sparse_rule(rng):
    """A rule whose filters match rarely, so expansion walks many periods per
    printed occurrence (anniversaries on a given weekday, Friday the 13th,
    week-53 days, the fifth weekday of February, leap days)."""
    dt = gt.rand_dt(rng, 1000, 2100)
    wd = rng.choice(WD)
    kind = rng.randrange(10)
    if kind == 0:
        rule = 'FREQ=MONTHLY;BYDAY=%s;BYMONTHDAY=%d' % (wd, rng.choice([13, 1, 31, -1, 29]))
    elif kind == 1:
        rule = 'FREQ=YEARLY;BYMONTH=%d;BYMONTHDAY=%d;BYDAY=%s' % (
            rng.randint(1, 12), rng.randint(1, 28), wd)
    elif kind == 2:
        rule = 'FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29;BYDAY=%s' % wd
    elif kind == 3:
        rule = 'FREQ=YEARLY;BYWEEKNO=53;BYDAY=%s;WKST=%s' % (wd, rng.choice(WD))
    elif kind == 4:
        rule = 'FREQ=YEARLY;BYMONTH=2;BYDAY=5%s' % wd
    elif kind == 5:
        rule = 'FREQ=YEARLY;BYYEARDAY=366;BYDAY=%s' % wd
    elif kind == 6:
        rule = 'FREQ=DAILY;BYMONTH=%d;BYMONTHDAY=%d;BYDAY=%s' % (
            rng.randint(1, 12), rng.randint(1, 28), wd)
    elif kind == 7:
        rule = 'FREQ=DAILY;BYMONTH=2;BYMONTHDAY=29;BYDAY=%s' % wd
    elif kind == 8:
        rule = 'FREQ=MONTHLY;BYDAY=5%s;BYMONTH=%d' % (wd, rng.choice([2, 4, 6, 9, 11]))
    else:
        rule = 'FREQ=YEARLY;BYWEEKNO=1;BYDAY=%s;BYMONTH=12;WKST=%s' % (wd, rng.choice(WD))
    if rng.random() < 0.3:
        rule += ';INTERVAL=%d' % rng.choice([2, 3, 4])
    return '%s %s %d' % (dt, rule, rng.choice([2000, 5000, 100000]))


def sparse_sweeps(count, seed=9201):
    rng = random.Random(seed)
    return [sparse_rule(rng) for _ in range(count)]


def mixed(scale=1):
    """Realistic mixed traffic: rules with the full range of BY values
    (BYSETPOS, BYWEEKNO, ordinals, any WKST), ordinary calendar events, some
    sparse rules that sweep far ahead, and a few long expansions. With
    scale > 1 every group is scale times larger (fresh seeds) and the long
    expansions are variations of the ten fixed ones."""
    seed = 9300 if scale == 1 else 19300
    lines = gt.gen_lines(seed + 1, 3400 * scale, n_choices=(1, 5, 10, 30),
                         maker=gt.rand_rule_wide, max_years=12)
    rng = random.Random(seed + 2)
    lines += [calendar_event(rng).rsplit(' ', 1)[0] + ' 20' for _ in range(1500 * scale)]
    rng = random.Random(seed + 3)
    lines += [sparse_rule(rng).rsplit(' ', 1)[0] + ' 500' for _ in range(MIXED_SPARSE * scale)]
    if scale == 1:
        lines += LONG_EXPANSIONS
    else:
        rng = random.Random(seed + 4)
        lines += [long_expansion(rng, i % len(LONG_EXPANSIONS)) for i in range(len(LONG_EXPANSIONS) * scale)]
    random.Random(seed).shuffle(lines)
    return lines


LONG_EXPANSIONS = [
    '19700101T083000 FREQ=DAILY 50000',
    '18000101T000000 FREQ=WEEKLY;BYDAY=MO,WE,FR;WKST=SU 60000',
    '20000101T090000 FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1 7000',
    '15000101T000000 FREQ=YEARLY;BYWEEKNO=1,20,-1;BYDAY=TU,TH 20000',
    '10000101T120000 FREQ=MONTHLY;BYDAY=2TU,-1FR 20000',
    '12000101T000000 FREQ=YEARLY;BYDAY=20MO,-20FR,1SU 20000',
    '10000101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29;BYDAY=FR 100000',
    '10000101T000000 FREQ=DAILY;BYMONTH=2;BYMONTHDAY=29;BYDAY=SU 100000',
    '16000101T000000 FREQ=MONTHLY;BYMONTHDAY=13;BYDAY=FR 100000',
    '10000101T000000 FREQ=YEARLY;BYWEEKNO=53;BYDAY=TH;WKST=SU 100000',
]


def long_expansion(rng, kind):
    """A variation of LONG_EXPANSIONS[kind]: same frequency, filters and N, with
    a different start, time of day and weekdays."""
    def dt(y0, y1):
        return '%04d0101T%02d%02d00' % (rng.randint(y0, y1), rng.randrange(24), rng.choice([0, 15, 30, 45]))
    wd = rng.choice(WD)
    if kind == 0:
        return '%s FREQ=DAILY %d' % (gt.rand_dt(rng, 1700, 2000), rng.choice([20000, 50000]))
    if kind == 1:
        days = ','.join(sorted(rng.sample(WD, 3), key=WD.index))
        return '%s FREQ=WEEKLY;BYDAY=%s;WKST=%s 60000' % (dt(1500, 1900), days, rng.choice(WD))
    if kind == 2:
        return '%s FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=%d 7000' % (dt(1000, 3000), rng.choice([1, -1]))
    if kind == 3:
        weeks = ','.join(map(str, sorted(rng.sample([1, 10, 20, 30, 40, 52, -1, -2], 3))))
        days = ','.join(sorted(rng.sample(WD, 2), key=WD.index))
        return '%s FREQ=YEARLY;BYWEEKNO=%s;BYDAY=%s 20000' % (dt(1200, 2000), weeks, days)
    if kind == 4:
        return '%s FREQ=MONTHLY;BYDAY=%d%s,-1%s 20000' % (dt(1000, 2000), rng.randint(1, 4), wd, rng.choice(WD))
    if kind == 5:
        return '%s FREQ=YEARLY;BYDAY=%d%s,-%d%s 20000' % (dt(1000, 2000), rng.randint(1, 53), wd,
                                                         rng.randint(1, 53), rng.choice(WD))
    if kind == 6:
        return '%s FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29;BYDAY=%s 100000' % (dt(1000, 1600), wd)
    if kind == 7:
        return '%s FREQ=DAILY;BYMONTH=2;BYMONTHDAY=29;BYDAY=%s 100000' % (dt(1000, 1600), wd)
    if kind == 8:
        return '%s FREQ=MONTHLY;BYMONTHDAY=13;BYDAY=%s 100000' % (dt(1000, 1600), wd)
    return '%s FREQ=YEARLY;BYWEEKNO=53;BYDAY=%s;WKST=%s 100000' % (dt(1000, 1600), wd, rng.choice(WD))


# Long tier (../bench-long): the same three workloads with more rules and so
# more work per input; see NOTES.md. Lines and output may exceed the short
# limits (SPEC.md gives the long-tier limits).
LONG_DIR = os.path.join(PROBLEM, 'bench-long')
LONG_MAX_LINES = 100000
LONG_MAX_OUT = 100_000_000
LONG_CAL_EVENTS = 70000
LONG_CAL_SEASONAL = 0.65
LONG_SPARSE_RULES = 1000
LONG_MIXED_SCALE = 15


def run(cmd, data):
    proc = subprocess.run(cmd, input=data.encode(), capture_output=True, timeout=4 * 3600)
    assert proc.returncode == 0, proc.stderr.decode()
    return proc.stdout.decode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--long', action='store_true', help='write the long tier to bench-long/')
    ap.add_argument('--only', action='append', default=[],
                    help='regenerate only this case (e.g. 002_sparse_sweeps); repeatable')
    ap.add_argument('--agree', action='append', default=[], metavar='RUN_SH',
                    help='take the expected output from these implementations instead of '
                         'reference/main.py, requiring them all to agree byte for byte; repeatable')
    args = ap.parse_args()
    if args.long:
        out_dir, max_lines, max_out = LONG_DIR, LONG_MAX_LINES, LONG_MAX_OUT
        cases = [
            ('calendar_sync', lambda: calendar_sync_long(LONG_CAL_EVENTS, LONG_CAL_SEASONAL)),
            ('sparse_sweeps', lambda: sparse_sweeps(LONG_SPARSE_RULES, seed=19201)),
            ('mixed_workload', lambda: mixed(LONG_MIXED_SCALE)),
        ]
    else:
        out_dir, max_lines, max_out = HERE, MAX_LINES, MAX_OUT
        cases = [
            ('calendar_sync', calendar_sync),
            ('sparse_sweeps', lambda: sparse_sweeps(SPARSE_RULES)),
            ('mixed_workload', mixed),
        ]
    os.makedirs(out_dir, exist_ok=True)
    names = ['%03d_%s' % (idx, name) for idx, (name, _) in enumerate(cases, 1)]
    for o in args.only:
        assert o in names, o
    selected = [n for n in names if not args.only or n in args.only]
    for f in os.listdir(out_dir):
        if (f.endswith('.in') or f.endswith('.out')) and f.rsplit('.', 1)[0] in selected:
            os.remove(os.path.join(out_dir, f))
    check = os.path.exists(gt.ORACLE_PY) and not os.environ.get('NO_ORACLE') and not args.long
    for base, (name, make) in zip(names, cases):
        if base not in selected:
            continue
        lines = make()
        assert len(lines) <= max_lines, name
        for line in lines:
            gt.validate(line)
        data = '\n'.join(lines) + '\n'
        if args.agree:
            outs = [run([cmd], data) for cmd in args.agree]
            for cmd, out in zip(args.agree, outs):
                assert out == outs[0], '%s disagrees with %s on %s' % (cmd, args.agree[0], base)
            expected = outs[0]
        else:
            expected = run([sys.executable, REF], data)
        assert len(expected) < max_out, (base, len(expected))
        if check:
            oracle = run([gt.ORACLE_PY, '-c', gt.ORACLE_SRC], data)
            assert oracle == expected, 'dateutil disagrees on ' + base
        with open(os.path.join(out_dir, base + '.in'), 'w') as f:
            f.write(data)
        with open(os.path.join(out_dir, base + '.out'), 'w') as f:
            f.write(expected)
        nocc = sum(len(l.split()) for l in expected.split('\n') if l)
        print('%-24s %5d rules %8d occurrences %9d bytes%s%s'
              % (base, len(lines), nocc, len(expected), ' (dateutil agrees)' if check else '',
                 ' (%d implementations agree)' % len(args.agree) if args.agree else ''), flush=True)


if __name__ == '__main__':
    main()
