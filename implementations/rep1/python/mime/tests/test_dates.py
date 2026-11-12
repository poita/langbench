import pytest

from mimedump.dates import civil_from_days, days_from_civil, parse_date


@pytest.mark.parametrize(
    ("raw", "epoch", "utc", "offset"),
    [
        ("Sun, 29 Feb 2004 22:03:22 -0800", 1078121002, "2004-03-01T06:03:22Z", "-0800"),
        ("3 Jan 70 00:00:00 GMT", 172800, "1970-01-03T00:00:00Z", "+0000"),
        ("Tue, 1 Jan 2036 00:00:60 +0000", 2082758460, "2036-01-01T00:01:00Z", "+0000"),
        ("Mon, 3 Mar 1969 12:00 (GMT) -0500", -26204400, "1969-03-03T17:00:00Z", "-0500"),
        ("Sun, 07 Mar 2004 15:21:26 -0000", 1078672886, "2004-03-07T15:21:26Z", "+0000"),
        ("1 Jan 2000 00:00:00 +2359", 946598460, "1999-12-31T00:01:00Z", "+2359"),
        ("1 Jan 2000 00:00 +9999", 946684800 - 6039 * 60, "1999-12-27T19:21:00Z", "+10039"),
        ("1 jan 2000 00:00:00 est", 946684800 + 18000, "2000-01-01T05:00:00Z", "-0500"),
        ("1 Jan 2000 00:00:00 bogus", 946684800, "2000-01-01T00:00:00Z", "+0000"),
        ("1 Jan 2000 00:00:00", 946684800, "2000-01-01T00:00:00Z", "+0000"),
        ("1 Jan 100 00:00:00", days_from_civil(2000, 1, 1) * 86400, "2000-01-01T00:00:00Z", "+0000"),
    ],
)
def test_valid_dates(raw, epoch, utc, offset):
    d = parse_date(raw)
    assert d is not None
    assert (d.epoch, d.utc, d.offset) == (epoch, utc, offset)


@pytest.mark.parametrize(
    "raw",
    [
        "not a date",
        "",
        "1 Jan 2000",
        "32 Jan 2000 00:00",
        "0 Jan 2000 00:00",
        "30 Feb 2000 00:00",
        "29 Feb 2001 00:00",
        "1 Foo 2000 00:00",
        "1 January 2000 00:00",
        "1 Jan 2000 24:00",
        "1 Jan 2000 00:60",
        "1 Jan 2000 00:00:61",
        "1 Jan 0000 00:00",
        "1 Jan 20000 00:00",
        "1 Jan 2000 0000",
        "Mon 1 Jan",
    ],
)
def test_invalid_dates(raw):
    assert parse_date(raw) is None


def test_leap_years():
    assert parse_date("29 Feb 2000 00:00") is not None
    assert parse_date("29 Feb 1900 00:00") is None
    assert parse_date("29 Feb 2004 00:00") is not None


def test_day_conversions_roundtrip():
    assert days_from_civil(1970, 1, 1) == 0
    assert days_from_civil(1969, 12, 31) == -1
    for days in range(-800000, 3000000, 997):
        assert days_from_civil(*civil_from_days(days)) == days
