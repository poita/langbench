from rrule import DateTime, Rule, occurrences


def expand(dtstart, rule, limit=None):
    return [str(o) for o in occurrences(DateTime.parse(dtstart), Rule.parse(rule), limit)]


def test_rfc_last_friday_every_other_month():
    got = expand("19970902T090000", "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=10")
    assert got[:3] == ["19970926T090000", "19971128T090000", "19980130T090000"]
    assert len(got) == 10


def test_weekly_wkst_matters():
    sunday = expand("19970902T090000", "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH;COUNT=8")
    assert [s[:8] for s in sunday] == ["19970902", "19970904", "19970916", "19970918", "19970930", "19971002", "19971014", "19971016"]
    monday = expand("19970902T090000", "FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4")
    assert [s[:8] for s in monday] == ["19970902", "19970907", "19970916", "19970921"]


def test_defaults_leap_day_and_month_end():
    assert expand("20240229T120000", "FREQ=YEARLY;COUNT=3") == ["20240229T120000", "20280229T120000", "20320229T120000"]
    assert [s[:8] for s in expand("20240131T000000", "FREQ=MONTHLY;COUNT=3")] == ["20240131", "20240331", "20240531"]


def test_until_is_inclusive_and_may_precede_dtstart():
    got = expand("20240131T000000", "FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240430T000000")
    assert [s[:8] for s in got] == ["20240131", "20240229", "20240331", "20240430"]
    assert expand("20240131T000000", "FREQ=DAILY;UNTIL=20240130T000000") == []
    # UNTIL on the same date but with an earlier time of day excludes it
    assert expand("20240131T120000", "FREQ=DAILY;UNTIL=20240131T110000") == []
    assert expand("20240131T120000", "FREQ=DAILY;UNTIL=20240131T120000") == ["20240131T120000"]


def test_bysetpos():
    got = expand("20240301T080000", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3")
    assert [s[:8] for s in got] == ["20240329", "20240430", "20240531"]
    # set position applies before the DTSTART check
    got = expand("20240320T000000", "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;COUNT=2")
    assert [s[:8] for s in got] == ["20240401", "20240506"]
    assert expand("20240315T000000", "FREQ=MONTHLY;BYSETPOS=2;COUNT=2") == []
    assert expand("20240315T000000", "FREQ=MONTHLY;BYSETPOS=1;COUNT=2")[0] == "20240315T000000"


def test_yearly_ordinal_with_bymonth():
    got = expand("20240101T000000", "FREQ=YEARLY;BYMONTH=1,7;BYDAY=2MO;COUNT=4")
    assert [s[:8] for s in got] == ["20240108", "20240708", "20250113", "20250714"]


def test_yearly_ordinal_whole_year():
    got = expand("20240101T000000", "FREQ=YEARLY;BYDAY=-1MO,53FR;COUNT=3")
    assert [s[:8] for s in got] == ["20241230", "20251229", "20261228"]  # 53FR absent in these years


def test_byweekno():
    got = expand("20200101T000000", "FREQ=YEARLY;BYWEEKNO=53;BYDAY=MO;COUNT=3")
    assert [s[:8] for s in got] == ["20201228", "20261228", "20321227"]
    got = expand("20110101T000000", "FREQ=YEARLY;BYWEEKNO=53;COUNT=4")
    assert [s[:8] for s in got] == ["20110101", "20110102", "20151228", "20151229"]


def test_byyearday_negative():
    got = expand("20240101T000000", "FREQ=YEARLY;BYYEARDAY=1,-1;COUNT=4")
    assert [s[:8] for s in got] == ["20240101", "20241231", "20250101", "20251231"]


def test_never_matching_rule_terminates_empty():
    assert expand("20260101T000000", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5") == []
    assert expand("20260101T000000", "FREQ=MONTHLY;BYMONTHDAY=31;BYMONTH=2") == []


def test_stops_after_year_9999():
    got = expand("99981231T000000", "FREQ=DAILY")
    assert got == ["99981231T000000"] + [f"9999{m:02d}{d:02d}T000000" for m, d in _all_days_9999()]
    assert expand("99990101T000000", "FREQ=YEARLY;INTERVAL=1") == ["99990101T000000"]


def _all_days_9999():
    lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return [(m + 1, d) for m, n in enumerate(lengths) for d in range(1, n + 1)]


def test_limit_and_count_take_the_smaller():
    assert len(expand("20240101T000000", "FREQ=DAILY;COUNT=5", limit=3)) == 3
    assert len(expand("20240101T000000", "FREQ=DAILY;COUNT=5", limit=9)) == 5


def test_occurrences_before_dtstart_do_not_count():
    got = expand("20240320T000000", "FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=1,31;COUNT=2")
    assert [s[:8] for s in got] == ["20240331", "20250301"]


def test_lazy_iteration():
    it = occurrences(DateTime(2024, 1, 1), Rule.parse("FREQ=DAILY"))
    assert next(it) == DateTime(2024, 1, 1)
    assert next(it) == DateTime(2024, 1, 2)


def test_weekly_crosses_month_and_year():
    got = expand("20231228T100000", "FREQ=WEEKLY;BYDAY=TH,FR,SA,MO;WKST=MO;COUNT=6")
    assert [s[:8] for s in got] == ["20231228", "20231229", "20231230", "20240101", "20240104", "20240105"]
