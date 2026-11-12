import pytest

from rrule import DateTime, Rule, RuleError, parse_line


def test_datetime_parse_and_format():
    dt = DateTime.parse("19970902T090000")
    assert dt == DateTime(1997, 9, 2, 9, 0, 0)
    assert str(dt) == "19970902T090000"


def test_datetime_ordering_is_chronological():
    assert DateTime(2020, 1, 31, 23) < DateTime(2020, 2, 1)


@pytest.mark.parametrize("text", ["20230229T000000", "20240101T240000", "2024-01-01", "20241301T000000"])
def test_datetime_rejects_invalid(text):
    with pytest.raises(RuleError):
        DateTime.parse(text)


def test_rule_parse_all_parts():
    r = Rule.parse(
        "FREQ=YEARLY;INTERVAL=2;WKST=SU;BYMONTH=1,7;BYMONTHDAY=-1,5;BYDAY=2MO,-1FR;BYSETPOS=1,-1;UNTIL=20300101T000000"
    )
    assert r.freq == "YEARLY" and r.interval == 2 and r.wkst == 6
    assert r.by_month == (1, 7)
    assert r.by_month_day == (-1, 5)
    assert r.by_day == ((2, 0), (-1, 4))
    assert r.by_set_pos == (1, -1)
    assert r.until == DateTime(2030, 1, 1)
    assert r.count is None


def test_rule_plain_byday_and_weekno():
    r = Rule.parse("FREQ=YEARLY;BYWEEKNO=53,-1;BYDAY=MO,SU;BYYEARDAY=366,-366;COUNT=3")
    assert r.by_day == ((0, 0), (0, 6))
    assert r.by_week_no == (53, -1)
    assert r.by_year_day == (366, -366)
    assert r.count == 3


@pytest.mark.parametrize("text", ["INTERVAL=2", "FREQ=HOURLY", "FREQ=DAILY;FOO=1", "FREQ=DAILY;COUNT", "FREQ=DAILY;BYDAY=XX"])
def test_rule_rejects_invalid(text):
    with pytest.raises(RuleError):
        Rule.parse(text)


def test_parse_line():
    dtstart, rule, limit = parse_line("19970902T090000 FREQ=DAILY;COUNT=3 10")
    assert dtstart == DateTime(1997, 9, 2, 9) and rule.freq == "DAILY" and limit == 10


def test_parse_line_rejects_bad_shape():
    with pytest.raises(RuleError):
        parse_line("19970902T090000 FREQ=DAILY")
