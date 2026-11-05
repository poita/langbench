#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `rrule` problem.

Every test is either a hand-written list of rules or produced by a seeded
generator, so re-running this script reproduces the suite exactly. Expected
outputs come from reference/main.py, and every output line is cross-checked
against python-dateutil (the oracle for this problem) running in the
.oracle-venv; any disagreement aborts generation.

Run with the venv interpreter or plain python3: the oracle is invoked in a
subprocess with the venv's interpreter either way.
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
TESTS = os.path.join(HERE, 'tests')
REF = os.path.join(HERE, 'reference', 'main.py')
ORACLE_PY = os.path.join(ROOT, '.oracle-venv', 'bin', 'python')

sys.path.insert(0, os.path.join(HERE, 'reference'))
import main as ref  # noqa: E402  (calendar helpers for the validator and generator)

WD = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU']

cases = []


def add(name, lines):
    cases.append((name, list(lines)))


# ---------------------------------------------------------------------------
# Input validation against the restrictions stated in SPEC.md
# ---------------------------------------------------------------------------
def valid_dt(s):
    assert len(s) == 15 and s[8] == 'T' and s[:8].isdigit() and s[9:].isdigit(), s
    y, m, d, hh, mm, ss = ref.parse_dt(s)
    assert 1000 <= y <= 9999 and 1 <= m <= 12 and 1 <= d <= ref.days_in_month(y, m), s
    assert 0 <= hh <= 23 and 0 <= mm <= 59 and 0 <= ss <= 59, s


def validate(line):
    dt, rule, n = line.split(' ')
    valid_dt(dt)
    assert 1 <= int(n) <= 100000, line
    parts = {}
    for p in rule.split(';'):
        k, v = p.split('=')
        assert k not in parts, line
        parts[k] = v
    freq = parts['FREQ']
    assert freq in ('YEARLY', 'MONTHLY', 'WEEKLY', 'DAILY'), line
    assert not ('COUNT' in parts and 'UNTIL' in parts), line

    def intlist(key, lo, hi, zero_ok=False):
        vals = [int(v) for v in parts[key].split(',')]
        assert len(set(vals)) == len(vals), line
        for v in vals:
            assert lo <= v <= hi and (zero_ok or v != 0), line
        return vals

    for k, v in parts.items():
        if k == 'FREQ':
            pass
        elif k == 'INTERVAL':
            assert 1 <= int(v) <= 100, line
        elif k == 'COUNT':
            assert 1 <= int(v) <= 100000, line
        elif k == 'UNTIL':
            valid_dt(v)
        elif k == 'WKST':
            assert v in WD, line
        elif k == 'BYMONTH':
            intlist(k, 1, 12)
        elif k == 'BYMONTHDAY':
            intlist(k, -31, 31)
        elif k == 'BYYEARDAY':
            assert freq == 'YEARLY', line
            intlist(k, -366, 366)
        elif k == 'BYWEEKNO':
            assert freq == 'YEARLY', line
            intlist(k, -53, 53)
        elif k == 'BYSETPOS':
            intlist(k, -366, 366)
        elif k == 'BYDAY':
            items = v.split(',')
            assert len(set(items)) == len(items), line
            kinds = set()
            for it in items:
                assert it[-2:] in WD, line
                if len(it) > 2:
                    kinds.add('ord')
                    assert freq in ('MONTHLY', 'YEARLY') and 'BYWEEKNO' not in parts, line
                    o = int(it[:-2])
                    assert it[0] != '+' and o != 0, line
                    lim = 53 if (freq == 'YEARLY' and 'BYMONTH' not in parts) else 5
                    assert -lim <= o <= lim, line
                else:
                    kinds.add('plain')
            assert len(kinds) == 1, line
        else:
            raise AssertionError('unknown part in ' + line)


# ---------------------------------------------------------------------------
# Hand-written cases
# ---------------------------------------------------------------------------
add('daily_count', [
    '20240101T090000 FREQ=DAILY;COUNT=3 10',
    '20240101T090000 FREQ=DAILY;COUNT=3 2',
    '20240101T090000 FREQ=DAILY 5',
    '20231230T235959 FREQ=DAILY;COUNT=4 10',
])
add('yearly_default', [
    '20240315T101500 FREQ=YEARLY;COUNT=4 10',
    '20240315T101500 FREQ=YEARLY 3',
    '19991231T000000 FREQ=YEARLY;INTERVAL=2;COUNT=5 10',
])
add('monthly_default', [
    '20240115T080000 FREQ=MONTHLY;COUNT=5 10',
    '20240131T080000 FREQ=MONTHLY;COUNT=5 10',
    '20240130T080000 FREQ=MONTHLY;COUNT=5 10',
    '20240229T080000 FREQ=MONTHLY;COUNT=5 10',
    '20241115T080000 FREQ=MONTHLY;INTERVAL=3;COUNT=4 10',
])
add('weekly_default', [
    '20240103T070000 FREQ=WEEKLY;COUNT=4 10',
    '20240107T070000 FREQ=WEEKLY;COUNT=4 10',
    '20240101T070000 FREQ=WEEKLY;INTERVAL=2;COUNT=4 10',
    '20241225T070000 FREQ=WEEKLY;INTERVAL=3 3',
])
add('daily_interval', [
    '20240227T120000 FREQ=DAILY;INTERVAL=2;COUNT=5 10',
    '20230227T120000 FREQ=DAILY;INTERVAL=2;COUNT=5 10',
    '20240101T120000 FREQ=DAILY;INTERVAL=100;COUNT=5 10',
    '20240101T120000 FREQ=DAILY;INTERVAL=7;BYDAY=MO;COUNT=3 10',
    '20240101T120000 FREQ=DAILY;INTERVAL=7;BYDAY=TU;COUNT=3 10',
])
add('count_and_n', [
    '20240101T000000 FREQ=DAILY;COUNT=10 3',
    '20240101T000000 FREQ=DAILY;COUNT=3 10',
    '20240101T000000 FREQ=DAILY;COUNT=1 1',
    '20240101T000000 FREQ=DAILY;COUNT=100000 7',
    '20240101T000000 FREQ=DAILY 1',
])
add('until_boundaries', [
    '20240101T090000 FREQ=DAILY;UNTIL=20240104T090000 10',
    '20240101T090000 FREQ=DAILY;UNTIL=20240104T085959 10',
    '20240101T090000 FREQ=DAILY;UNTIL=20240104T090001 10',
    '20240101T090000 FREQ=DAILY;UNTIL=20240101T090000 10',
    '20240101T090000 FREQ=DAILY;UNTIL=20240101T085959 10',
    '20240101T090000 FREQ=DAILY;UNTIL=20231231T235959 10',
    '20240101T090000 FREQ=DAILY;UNTIL=10000101T000000 10',
    '20240131T090000 FREQ=MONTHLY;UNTIL=20240731T090000 10',
    '20240131T090000 FREQ=MONTHLY;UNTIL=20240731T085959 10',
    '20240101T090000 FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=20240110T090000 10',
])
add('leap_day_yearly', [
    '20240229T120000 FREQ=YEARLY;COUNT=5 10',
    '20240229T120000 FREQ=YEARLY;INTERVAL=4;COUNT=5 10',
    '20960229T120000 FREQ=YEARLY 4',
    '20960229T120000 FREQ=YEARLY;INTERVAL=2 3',
    '20000229T120000 FREQ=YEARLY;INTERVAL=100 5',
    '20240228T120000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29 3',
    '20230101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=-1;COUNT=6 10',
    '20240229T120000 FREQ=MONTHLY;COUNT=4 10',
    '20240229T120000 FREQ=MONTHLY;INTERVAL=12;COUNT=3 10',
    '20240229T120000 FREQ=YEARLY;BYYEARDAY=60;COUNT=4 10',
    '20240229T120000 FREQ=YEARLY;BYYEARDAY=-306;COUNT=4 10',
])
add('month_end', [
    '20240101T000000 FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=13 20',
    '20240101T000000 FREQ=MONTHLY;BYMONTHDAY=31;COUNT=8 20',
    '20240101T000000 FREQ=MONTHLY;BYMONTHDAY=30;COUNT=8 20',
    '20240101T000000 FREQ=MONTHLY;BYMONTHDAY=29;COUNT=8 20',
    '20230101T000000 FREQ=MONTHLY;BYMONTHDAY=29;COUNT=8 20',
    '20240101T000000 FREQ=MONTHLY;BYMONTHDAY=-1,-2,1;COUNT=9 20',
    '20240101T000000 FREQ=MONTHLY;BYMONTHDAY=-31;COUNT=5 20',
    '20240101T000000 FREQ=MONTHLY;BYMONTHDAY=-30;COUNT=5 20',
    '20240101T000000 FREQ=MONTHLY;BYMONTHDAY=-29;COUNT=5 20',
    '20240115T000000 FREQ=MONTHLY;BYMONTHDAY=15,-15;COUNT=6 20',
    '20240101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=-1;COUNT=5 20',
    '20240101T000000 FREQ=DAILY;BYMONTHDAY=-1;COUNT=5 20',
    '20240101T000000 FREQ=WEEKLY;BYMONTHDAY=-1,1;COUNT=6 20',
])
add('byday_ordinals_monthly', [
    '20240101T000000 FREQ=MONTHLY;BYDAY=2MO;COUNT=6 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=-1FR;COUNT=6 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=5SU;COUNT=6 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=-5SU;COUNT=6 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=1MO,-1MO;COUNT=8 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=2TU,4TH;COUNT=8 20',
    '20240101T000000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=6 20',
    '20240115T000000 FREQ=MONTHLY;BYDAY=1MO;COUNT=3 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=-1FR;BYMONTHDAY=-1,-2,-3;COUNT=4 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=1FR;BYMONTH=1,3,5;COUNT=5 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=3WE;BYSETPOS=1;COUNT=4 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=1MO,1TU,1WE,1TH,1FR;BYSETPOS=1;COUNT=6 20',
])
add('byday_ordinals_yearly', [
    '20240101T000000 FREQ=YEARLY;BYMONTH=1,7;BYDAY=2MO;COUNT=6 20',
    '20240101T000000 FREQ=YEARLY;BYMONTH=5;BYDAY=-1MO;COUNT=4 20',
    '20240101T000000 FREQ=YEARLY;BYMONTH=11;BYDAY=4TH;COUNT=4 20',
    '20240101T000000 FREQ=YEARLY;BYDAY=1MO;COUNT=4 20',
    '20240101T000000 FREQ=YEARLY;BYDAY=-1FR;COUNT=4 20',
    '20240101T000000 FREQ=YEARLY;BYDAY=20MO,-20FR;COUNT=8 20',
    '20200101T000000 FREQ=YEARLY;BYDAY=53FR;COUNT=4 20',
    '20200101T000000 FREQ=YEARLY;BYDAY=53WE,53TH;COUNT=6 20',
    '20200101T000000 FREQ=YEARLY;BYDAY=-53WE;COUNT=4 20',
    '20200101T000000 FREQ=YEARLY;BYDAY=-53MO;COUNT=4 20',
    '20240101T000000 FREQ=YEARLY;BYMONTH=2;BYDAY=5TH;COUNT=3 20',
    '20240101T000000 FREQ=YEARLY;BYMONTH=2;BYDAY=-5TH;COUNT=3 20',
    '20240101T000000 FREQ=YEARLY;BYMONTH=1,2,3;BYDAY=1SA,-1SA;BYSETPOS=1,-1;COUNT=6 20',
    '20240101T000000 FREQ=YEARLY;BYDAY=2MO;BYMONTHDAY=8,9,10,11,12,13,14;COUNT=4 20',
])
add('bysetpos', [
    '20240101T000000 FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=6 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1;COUNT=6 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1,-1;COUNT=8 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1,1;COUNT=8 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=SA,SU;BYSETPOS=2,-2;COUNT=8 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=SA,SU;BYSETPOS=10;COUNT=3 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=SA,SU;BYSETPOS=9,-9,10;COUNT=3 20',
    '20240101T000000 FREQ=MONTHLY;BYDAY=SA,SU;BYSETPOS=-10;COUNT=3 20',
    '20240101T000000 FREQ=MONTHLY;BYMONTHDAY=1,2,3,4,5,6,7;BYDAY=MO;BYSETPOS=1;COUNT=4 20',
    '20240120T000000 FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;COUNT=3 20',
    '20240120T000000 FREQ=MONTHLY;BYDAY=MO;BYSETPOS=-1;COUNT=3 20',
    '20240101T000000 FREQ=YEARLY;BYDAY=MO;BYSETPOS=1,-1;COUNT=4 20',
    '20240101T000000 FREQ=YEARLY;BYMONTH=1,3;BYDAY=MO;BYSETPOS=1,-1;COUNT=4 20',
    '20240103T000000 FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=4 20',
    '20240103T000000 FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1;COUNT=4 20',
    '20240103T000000 FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1;WKST=WE;COUNT=4 20',
    '20240103T000000 FREQ=DAILY;BYSETPOS=1;COUNT=3 20',
    '20240103T000000 FREQ=DAILY;BYSETPOS=-1;COUNT=3 20',
    '20240103T000000 FREQ=DAILY;BYSETPOS=2;UNTIL=20240301T000000 20',
    '20240101T000000 FREQ=MONTHLY;BYSETPOS=-1;COUNT=1 20',
    '20240101T000000 FREQ=MONTHLY;BYSETPOS=1,-1;COUNT=4 20',
    '20240101T000000 FREQ=MONTHLY;BYMONTHDAY=-1;BYSETPOS=-1;COUNT=4 20',
])
add('weekly_wkst', [
    '19970902T090000 FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH;COUNT=8 100',
    '19970902T090000 FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,TH;COUNT=8 100',
    '19970905T090000 FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;COUNT=6 100',
    '19970905T090000 FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,SU;COUNT=6 100',
    '19970905T090000 FREQ=WEEKLY;INTERVAL=2;WKST=SA;BYDAY=TU,SU;COUNT=6 100',
    '19970905T090000 FREQ=WEEKLY;INTERVAL=2;WKST=FR;BYDAY=TU,SU;COUNT=6 100',
    '19970905T090000 FREQ=WEEKLY;INTERVAL=2;WKST=TH;BYDAY=TU,SU,FR;COUNT=6 100',
    '19970905T090000 FREQ=WEEKLY;WKST=WE;BYDAY=MO,TU,WE,TH,FR,SA,SU;COUNT=10 100',
    '19970905T090000 FREQ=WEEKLY;INTERVAL=3;WKST=TU;BYDAY=MO,TU,WE,TH,FR,SA,SU;COUNT=14 100',
    '20241230T090000 FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=MO,TU,WE,TH,FR,SA,SU;COUNT=12 100',
    '20241230T090000 FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=MO,TU,WE,TH,FR,SA,SU;COUNT=12 100',
    '20241230T090000 FREQ=WEEKLY;BYDAY=WE,SU;BYMONTH=1;COUNT=5 100',
    '20240101T090000 FREQ=WEEKLY;INTERVAL=1;WKST=SU;BYDAY=SU;COUNT=3 100',
    '20240107T090000 FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=SU,SA;COUNT=6 100',
    '20240107T090000 FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=SU,SA;COUNT=6 100',
])
add('byweekno_edges', [
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=53;BYDAY=MO;COUNT=3 10',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=53;COUNT=14 20',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=1;COUNT=21 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=1;BYDAY=MO;COUNT=6 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=-1;BYDAY=SU;COUNT=6 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=-1;COUNT=14 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=52;COUNT=14 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=-53;COUNT=14 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=-52;BYDAY=MO;COUNT=6 30',
    '20110101T000000 FREQ=YEARLY;BYWEEKNO=53;COUNT=4 10',
    '19940101T000000 FREQ=YEARLY;BYWEEKNO=53 30',
    '20220101T000000 FREQ=YEARLY;BYWEEKNO=53;COUNT=10 30',
    '20390101T000000 FREQ=YEARLY;BYWEEKNO=52,53;COUNT=20 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=1;WKST=SU;COUNT=21 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=53;WKST=SU;COUNT=14 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=53;WKST=TH;COUNT=14 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=1;WKST=TH;COUNT=14 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=-1;WKST=SA;COUNT=14 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO;COUNT=5 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO;WKST=SU;COUNT=5 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=1,53;BYDAY=TH;COUNT=10 30',
    '20200101T000000 FREQ=YEARLY;BYWEEKNO=2;BYSETPOS=1,-1;COUNT=6 30',
    '20200601T000000 FREQ=YEARLY;BYWEEKNO=1,2;BYMONTH=1;COUNT=10 30',
    '20200101T000000 FREQ=YEARLY;INTERVAL=3;BYWEEKNO=53;COUNT=10 30',
])
add('byyearday', [
    '20240101T000000 FREQ=YEARLY;BYYEARDAY=1;COUNT=3 10',
    '20240101T000000 FREQ=YEARLY;BYYEARDAY=366;COUNT=3 10',
    '20240101T000000 FREQ=YEARLY;BYYEARDAY=-366;COUNT=3 10',
    '20240101T000000 FREQ=YEARLY;BYYEARDAY=365,-365;COUNT=6 10',
    '20240101T000000 FREQ=YEARLY;BYYEARDAY=-1,1;COUNT=6 10',
    '20240101T000000 FREQ=YEARLY;BYYEARDAY=60,-306;COUNT=6 10',
    '20240101T000000 FREQ=YEARLY;BYYEARDAY=100,200,300;BYDAY=MO;COUNT=4 10',
    '20240101T000000 FREQ=YEARLY;BYYEARDAY=1,2,3,4,5,6,7;BYSETPOS=-1;COUNT=3 10',
    '20240701T000000 FREQ=YEARLY;BYYEARDAY=1,180,182,183,184;COUNT=6 10',
    '20240101T000000 FREQ=YEARLY;BYYEARDAY=60;BYMONTH=2;COUNT=3 10',
])
add('bymonth', [
    '20240115T000000 FREQ=YEARLY;BYMONTH=1,7;COUNT=6 20',
    '20240715T000000 FREQ=YEARLY;BYMONTH=1,7;COUNT=6 20',
    '20240131T000000 FREQ=YEARLY;BYMONTH=2,4,6;COUNT=6 20',
    '20240131T000000 FREQ=YEARLY;BYMONTH=1,3,5;COUNT=6 20',
    '20240101T000000 FREQ=MONTHLY;BYMONTH=2,3;COUNT=6 20',
    '20240115T000000 FREQ=MONTHLY;INTERVAL=2;BYMONTH=2,3;COUNT=6 20',
    '20240115T000000 FREQ=MONTHLY;INTERVAL=2;BYMONTH=2,4;COUNT=6 20',
    '20240125T000000 FREQ=DAILY;BYMONTH=2;COUNT=6 20',
    '20240125T000000 FREQ=DAILY;INTERVAL=3;BYMONTH=2,12;COUNT=6 20',
    '20240125T000000 FREQ=WEEKLY;BYMONTH=2;COUNT=6 20',
    '20240125T000000 FREQ=WEEKLY;INTERVAL=2;BYMONTH=2,3;BYDAY=MO,FR;COUNT=6 20',
    '20240101T000000 FREQ=YEARLY;BYMONTH=12,1;BYDAY=FR;COUNT=8 20',
    '20240101T000000 FREQ=YEARLY;BYMONTH=2;BYDAY=MO,TU,WE,TH,FR,SA,SU;BYSETPOS=-1;COUNT=4 20',
])
add('empty_results', [
    '20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5 10',
    '20260101T000000 FREQ=DAILY;COUNT=1 10',
    '20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30 10',
    '20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=31,-31 10',
    '20260101T000000 FREQ=MONTHLY;BYMONTH=2;BYMONTHDAY=31 10',
    '20260101T000000 FREQ=YEARLY;BYYEARDAY=366;INTERVAL=2;BYMONTH=1 10',
    '20260101T000000 FREQ=DAILY;UNTIL=20251231T000000 10',
    '20260101T000000 FREQ=DAILY;BYMONTH=2;BYMONTHDAY=30;UNTIL=20400101T000000 10',
    '20260101T000000 FREQ=WEEKLY;BYDAY=MO;BYSETPOS=2;UNTIL=20400101T000000 10',
    '20260101T000000 FREQ=MONTHLY;BYDAY=5MO;BYSETPOS=2 10',
    '20260101T000000 FREQ=YEARLY;BYDAY=MO;BYSETPOS=54,-54 10',
    '20260101T000000 FREQ=YEARLY;BYMONTH=4;BYMONTHDAY=-31 10',
    '20260101T000000 FREQ=YEARLY;BYWEEKNO=53;BYMONTH=6 10',
    '20260101T000000 FREQ=MONTHLY;BYMONTHDAY=31;BYDAY=MO,TU,WE,TH,FR,SA,SU;BYSETPOS=2 10',
    '20260101T000000 FREQ=DAILY;COUNT=2 10',
    '20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;BYSETPOS=1 10',
    '20260101T000000 FREQ=MONTHLY;BYMONTHDAY=30,31;BYMONTH=2 10',
    '20260228T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=28,29,30;COUNT=3 10',
])
add('year_9999_boundary', [
    '99900101T000000 FREQ=YEARLY 20',
    '99900101T000000 FREQ=YEARLY;INTERVAL=3 20',
    '99991231T235959 FREQ=YEARLY 5',
    '99991201T000000 FREQ=MONTHLY 5',
    '99990101T000000 FREQ=MONTHLY;INTERVAL=5 100',
    '99980601T000000 FREQ=MONTHLY;BYMONTHDAY=31 100',
    '99900101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29 100',
    '99900101T000000 FREQ=YEARLY;BYWEEKNO=53 100',
    '99900101T000000 FREQ=YEARLY;BYDAY=-1FR;BYMONTH=12 100',
    '99991201T000000 FREQ=DAILY;COUNT=10 100',
    '99991101T000000 FREQ=WEEKLY;INTERVAL=2;COUNT=3 100',
    '80000101T000000 FREQ=YEARLY;INTERVAL=100;BYMONTH=2;BYMONTHDAY=29 100',
])
add('dtstart_filter', [
    '20240120T000000 FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;COUNT=3 20',
    '20240120T000000 FREQ=MONTHLY;BYDAY=MO;COUNT=3 20',
    '20240620T000000 FREQ=YEARLY;BYMONTH=1,12;COUNT=4 20',
    '20240620T000000 FREQ=YEARLY;BYMONTH=1,6,12;BYMONTHDAY=1,20,25;COUNT=8 20',
    '20240620T120000 FREQ=YEARLY;BYMONTH=6;BYMONTHDAY=20;COUNT=2 20',
    '20240620T120000 FREQ=DAILY;BYMONTHDAY=19,20,21;COUNT=4 20',
    '20240620T120000 FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;COUNT=4 20',
    '20240620T120000 FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1;COUNT=3 20',
    '20240620T120000 FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3 20',
    '20240620T120000 FREQ=WEEKLY;WKST=TH;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1;COUNT=3 20',
    '20241231T120000 FREQ=YEARLY;BYWEEKNO=1;COUNT=8 20',
    '20241231T120000 FREQ=YEARLY;BYDAY=1MO;BYSETPOS=1;COUNT=3 20',
])
add('interval_carry', [
    '20240131T000000 FREQ=MONTHLY;INTERVAL=13;COUNT=5 20',
    '20240131T000000 FREQ=MONTHLY;INTERVAL=25;COUNT=5 20',
    '20240131T000000 FREQ=MONTHLY;INTERVAL=11;COUNT=8 20',
    '20240131T000000 FREQ=MONTHLY;INTERVAL=100;COUNT=5 20',
    '20240131T000000 FREQ=MONTHLY;INTERVAL=12;COUNT=5 20',
    '20241201T000000 FREQ=MONTHLY;INTERVAL=1;COUNT=3 20',
    '20240131T000000 FREQ=YEARLY;INTERVAL=7;COUNT=5 20',
    '20240131T000000 FREQ=YEARLY;INTERVAL=100;COUNT=5 20',
    '20240131T000000 FREQ=WEEKLY;INTERVAL=53;COUNT=5 20',
    '20240131T000000 FREQ=WEEKLY;INTERVAL=100;COUNT=5 20',
    '20240131T000000 FREQ=WEEKLY;INTERVAL=100;WKST=SU;BYDAY=MO,TU,WE,TH,FR,SA,SU;COUNT=10 20',
    '20240131T000000 FREQ=DAILY;INTERVAL=100;COUNT=5 20',
    '20240131T000000 FREQ=DAILY;INTERVAL=29;COUNT=5 20',
])
add('time_of_day', [
    '20240101T235959 FREQ=DAILY;COUNT=3 10',
    '20240101T000000 FREQ=DAILY;COUNT=3 10',
    '20240101T130507 FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=3 10',
    '20240101T130507 FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240331T130507 10',
    '20240101T130507 FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240331T130506 10',
    '20240101T130507 FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240331T235959 10',
    '20240101T000001 FREQ=YEARLY;UNTIL=20260101T000000 10',
    '20240101T000001 FREQ=YEARLY;UNTIL=20260101T000001 10',
])
add('early_years', [
    '10000101T000000 FREQ=YEARLY;COUNT=3 10',
    '10000101T000000 FREQ=WEEKLY;COUNT=3 10',
    '10000101T000000 FREQ=YEARLY;BYWEEKNO=1;COUNT=10 10',
    '10000101T000000 FREQ=YEARLY;BYWEEKNO=-1;COUNT=10 10',
    '10000101T000000 FREQ=YEARLY;BYWEEKNO=53;COUNT=10 10',
    '10040229T000000 FREQ=YEARLY;COUNT=3 10',
    '11000228T000000 FREQ=DAILY;COUNT=3 10',
    '12000228T000000 FREQ=DAILY;COUNT=3 10',
    '15821004T000000 FREQ=DAILY;COUNT=3 10',
    '17000228T000000 FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=3 10',
])


# ---------------------------------------------------------------------------
# Seeded random rules
# ---------------------------------------------------------------------------
def rand_dt(rng, y0, y1):
    y = rng.randint(y0, y1)
    m = rng.randint(1, 12)
    d = rng.randint(1, ref.days_in_month(y, m))
    return '%04d%02d%02dT%02d%02d%02d' % (y, m, d, rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59))


def rand_rule(rng, freq=None, y0=1950, y1=2060, max_years=20, p_setpos=0.3, p_weekno=0.25):
    """Returns (dtstart, rule) within the SPEC subset. Unbounded rules get an UNTIL a few years out."""
    if freq is None:
        freq = rng.choice(['YEARLY', 'MONTHLY', 'WEEKLY', 'DAILY'])
    # WEEKLY and DAILY rules stay well clear of year 9999 (see SPEC).
    dt = rand_dt(rng, y0, min(y1, 9000) if freq in ('WEEKLY', 'DAILY') else y1)
    parts = ['FREQ=' + freq]
    if rng.random() < 0.5:
        parts.append('INTERVAL=%d' % rng.choice([1, 1, 2, 2, 3, 4, 5, 7, 12, 13, 100]))
    has_month = rng.random() < 0.4
    if has_month:
        parts.append('BYMONTH=' + ','.join(map(str, sorted(rng.sample(range(1, 13), rng.randint(1, 3))))))
    has_weekno = freq == 'YEARLY' and rng.random() < p_weekno
    if has_weekno:
        parts.append('BYWEEKNO=' + ','.join(map(str, rng.sample([1, 2, 3, 20, 51, 52, 53, -1, -2, -52, -53], rng.randint(1, 3)))))
    if rng.random() < 0.3:
        parts.append('BYMONTHDAY=' + ','.join(map(str, rng.sample([1, 2, 15, 28, 29, 30, 31, -1, -2, -3, -15, -29, -30, -31], rng.randint(1, 3)))))
    if freq == 'YEARLY' and rng.random() < 0.2:
        parts.append('BYYEARDAY=' + ','.join(map(str, rng.sample([1, 2, 59, 60, 100, 200, 365, 366, -1, -2, -100, -365, -366], rng.randint(1, 3)))))
    if rng.random() < 0.5:
        if freq in ('YEARLY', 'MONTHLY') and not has_weekno and rng.random() < 0.5:
            lim = 5 if (freq == 'MONTHLY' or has_month) else 53
            pool = [1, 2, 3, 4, 5, -1, -2, -3, -4, -5] + ([10, 20, 52, 53, -53, -52, -20] if lim == 53 else [])
            items = set()
            for _ in range(rng.randint(1, 3)):
                items.add('%d%s' % (rng.choice(pool), rng.choice(WD)))
            parts.append('BYDAY=' + ','.join(sorted(items)))
        else:
            parts.append('BYDAY=' + ','.join(rng.sample(WD, rng.randint(1, 4))))
    if rng.random() < p_setpos:
        parts.append('BYSETPOS=' + ','.join(map(str, rng.sample([1, 2, 3, -1, -2, -3, 5, -5, 10, -10, 31, -31], rng.randint(1, 3)))))
    if rng.random() < 0.5:
        parts.append('WKST=' + rng.choice(WD))
    r = rng.random()
    if r < 0.45:
        parts.append('COUNT=%d' % rng.randint(1, 40))
    elif r < 0.8:
        parts.append('UNTIL=' + rand_dt(rng, int(dt[:4]) - 1, int(dt[:4]) + max_years))
    else:
        parts.append('UNTIL=%04d1231T235959' % (int(dt[:4]) + rng.randint(1, max_years)))
    return dt, ';'.join(parts)


def rand_rule_wide(rng, y0=1900, y1=2100, max_years=12):
    """Like rand_rule but draws list values from their full ranges (every BYWEEKNO,
    BYMONTHDAY, BYYEARDAY, BYSETPOS and ordinal value the SPEC allows) and places
    UNTIL at the DTSTART/UNTIL alignments that matter (equal to DTSTART, same day
    with another time, the day before DTSTART's year)."""
    freq = rng.choice(['YEARLY', 'MONTHLY', 'WEEKLY', 'DAILY'])
    dt = rand_dt(rng, y0, y1)
    yr = int(dt[:4])
    parts = ['FREQ=' + freq]
    if rng.random() < 0.5:
        parts.append('INTERVAL=%d' % rng.randint(1, 100))
    has_month = rng.random() < 0.35
    if has_month:
        parts.append('BYMONTH=' + ','.join(map(str, sorted(rng.sample(range(1, 13), rng.randint(1, 4))))))
    has_weekno = freq == 'YEARLY' and rng.random() < 0.35
    if has_weekno:
        pool = list(range(1, 54)) + list(range(-53, 0))
        parts.append('BYWEEKNO=' + ','.join(map(str, rng.sample(pool, rng.randint(1, 4)))))
    if rng.random() < 0.35:
        pool = list(range(1, 32)) + list(range(-31, 0))
        parts.append('BYMONTHDAY=' + ','.join(map(str, rng.sample(pool, rng.randint(1, 4)))))
    if freq == 'YEARLY' and rng.random() < 0.2:
        pool = list(range(1, 367)) + list(range(-366, 0))
        parts.append('BYYEARDAY=' + ','.join(map(str, rng.sample(pool, rng.randint(1, 4)))))
    if rng.random() < 0.55:
        if freq in ('YEARLY', 'MONTHLY') and not has_weekno and rng.random() < 0.5:
            lim = 5 if (freq == 'MONTHLY' or has_month) else 53
            pool = [x for x in range(-lim, lim + 1) if x]
            items = set()
            for _ in range(rng.randint(1, 4)):
                items.add('%d%s' % (rng.choice(pool), rng.choice(WD)))
            parts.append('BYDAY=' + ','.join(sorted(items)))
        else:
            parts.append('BYDAY=' + ','.join(rng.sample(WD, rng.randint(1, 7))))
    if rng.random() < 0.35:
        pool = [x for x in range(-40, 41) if x] + [366, -366, 100, -100]
        parts.append('BYSETPOS=' + ','.join(map(str, rng.sample(pool, rng.randint(1, 3)))))
    if rng.random() < 0.6:
        parts.append('WKST=' + rng.choice(WD))
    r = rng.random()
    if r < 0.4:
        parts.append('COUNT=%d' % rng.randint(1, 30))
    elif r < 0.55:
        u = rng.choice([dt, dt[:9] + '%02d%02d%02d' % (rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59)),
                        '%04d1231T235959' % (yr - 1), '%04d0101T000000' % yr])
        parts.append('UNTIL=' + u)
    else:
        parts.append('UNTIL=' + rand_dt(rng, yr, yr + rng.randint(0, max_years)))
    return dt, ';'.join(parts)


def occurrences(dt, rule, n):
    parsed = ref.Rule(rule, ref.parse_dt(dt))
    return sum(1 for _ in ref.expand(parsed, n))


def gen_lines(seed, count, n_choices=(1, 5, 20, 60), maker=None, **kw):
    """Random rules that each produce at least one occurrence; rules bounded only by
    COUNT reach it. Rules that never match are covered by hand-written tests, and
    excluding them here keeps every random rule's expansion short for both the
    reference and the oracle (which otherwise sweep every year up to 9999)."""
    rng = random.Random(seed)
    lines = []
    while len(lines) < count:
        dt, rule = (maker or rand_rule)(rng, **kw)
        n = rng.choice(n_choices)
        if 'COUNT=' in rule:
            # Probe within a bounded window first so a sparse rule never sweeps to 9999.
            probe = ';'.join(p for p in rule.split(';') if not p.startswith('COUNT='))
            probe += ';UNTIL=%04d1231T235959' % (int(dt[:4]) + kw.get('max_years', 20))
            want = min(n, int(rule.split('COUNT=')[1].split(';')[0]))
            if occurrences(dt, probe, want) < want:
                continue
        elif occurrences(dt, rule, 1) < 1:
            continue
        lines.append('%s %s %d' % (dt, rule, n))
    return lines


add('gen_yearly', gen_lines(101, 150, freq='YEARLY', max_years=60))
add('gen_monthly', gen_lines(102, 150, freq='MONTHLY', max_years=30))
add('gen_weekly', gen_lines(103, 150, freq='WEEKLY', max_years=10))
add('gen_daily', gen_lines(104, 150, freq='DAILY', max_years=6))
add('gen_bysetpos', gen_lines(105, 200, p_setpos=1.0, max_years=8))
add('gen_byweekno', gen_lines(106, 200, freq='YEARLY', p_weekno=1.0, max_years=60))
add('gen_mixed_small', gen_lines(107, 300, max_years=10))
add('gen_mixed_wide_years', gen_lines(108, 300, y0=1000, y1=9900, max_years=15))
add('gen_mixed_medium', gen_lines(109, 1000, max_years=8))
add('gen_wide_values', gen_lines(112, 400, n_choices=(1, 2, 5, 10, 30, 100), maker=rand_rule_wide, max_years=12))

# Long expansions: a single rule with a large N.
add('large_n_daily', [
    '19700101T000000 FREQ=DAILY 100000',
    '20000229T120000 FREQ=DAILY;INTERVAL=3 30000',
])
add('large_n_weekly', [
    '18000101T000000 FREQ=WEEKLY;BYDAY=MO,WE,FR;WKST=SU 100000',
    '20000101T000000 FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TU,WE,TH,FR,SA,SU;WKST=SU 50000',
])
add('large_n_monthly_yearly', [
    '20000101T000000 FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1 50000',
    '20000101T000000 FREQ=MONTHLY;BYMONTHDAY=-1 50000',
    '20000101T000000 FREQ=YEARLY;BYWEEKNO=53;BYDAY=FR 100000',
    '20000101T000000 FREQ=YEARLY;BYDAY=-1FR;BYMONTH=1,2,3,4,5,6,7,8,9,10,11,12 50000',
])
add('sweep_to_9999', [
    '10000101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29 100000',
    '10000101T000000 FREQ=YEARLY;INTERVAL=4;BYMONTH=2;BYMONTHDAY=29 100000',
    '10000101T000000 FREQ=YEARLY;BYWEEKNO=53;BYDAY=TH;WKST=SU 100000',
    '10000101T000000 FREQ=MONTHLY;INTERVAL=7;BYMONTHDAY=31 100000',
    '10000101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30 100000',
])
add('many_rules_a', gen_lines(110, 5000, n_choices=(1, 3, 10, 30), max_years=5))
add('many_rules_b', gen_lines(111, 5000, n_choices=(5, 20, 50), max_years=4, p_setpos=0.5))


# ---------------------------------------------------------------------------
# Oracle cross-check (python-dateutil in the venv, run as a subprocess)
# ---------------------------------------------------------------------------
ORACLE_SRC = r'''
import sys, datetime, warnings
warnings.simplefilter("ignore")
from dateutil.rrule import rrulestr
out = []
for line in sys.stdin.read().split("\n"):
    if not line.strip():
        continue
    dt, rule, n = line.split()
    n = int(n)
    r = rrulestr(rule, dtstart=datetime.datetime.strptime(dt, "%Y%m%dT%H%M%S"))
    occ = []
    for x in r:
        occ.append(x.strftime("%Y%m%dT%H%M%S"))
        if len(occ) >= n:
            break
    out.append(" ".join(occ))
sys.stdout.write("\n".join(out) + "\n")
'''


def run(cmd, data):
    proc = subprocess.run(cmd, input=data.encode(), capture_output=True, timeout=1800)
    assert proc.returncode == 0, proc.stderr.decode()
    return proc.stdout.decode()


def main():
    assert os.path.exists(ORACLE_PY), 'oracle venv missing: ' + ORACLE_PY
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith('.in') or f.endswith('.out'):
            os.remove(os.path.join(TESTS, f))
    names = set()
    total_bytes = 0
    for idx, (name, lines) in enumerate(cases, 1):
        assert name not in names, name
        names.add(name)
        for line in lines:
            validate(line)
        base = '%03d_%s' % (idx, name)
        data = '\n'.join(lines) + '\n'
        expected = run([sys.executable, REF], data)
        oracle = run([ORACLE_PY, '-c', ORACLE_SRC], data)
        exp_lines = expected.split('\n')
        ora_lines = oracle.split('\n')
        assert len(exp_lines) == len(ora_lines) == len(lines) + 1, base
        for k, (a, b) in enumerate(zip(exp_lines, ora_lines)):
            if a != b:
                print('ORACLE DISAGREES in %s line %d:\n  input:     %s\n  reference: %s\n  dateutil:  %s'
                      % (base, k + 1, lines[k] if k < len(lines) else '', a[:300], b[:300]))
                sys.exit(1)
        with open(os.path.join(TESTS, base + '.in'), 'w') as f:
            f.write(data)
        with open(os.path.join(TESTS, base + '.out'), 'w') as f:
            f.write(expected)
        total_bytes += len(data) + len(expected)
        nocc = sum(len(l.split()) for l in exp_lines if l)
        print('%-32s %5d rules %8d occurrences %9d bytes' % (base, len(lines), nocc, len(expected)))
    print('%d tests written, %.1f MB total' % (len(cases), total_bytes / 1e6))


if __name__ == '__main__':
    main()
