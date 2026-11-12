import datetime  # only used as an independent oracle in the tests

import pytest

from rrule import dates


def test_anchors():
    assert dates.to_day_number(1, 1, 1) == 0
    assert dates.weekday(1, 1, 1) == 0  # Monday
    assert dates.weekday(2000, 1, 1) == 5  # Saturday


@pytest.mark.parametrize("year,leap", [(1900, False), (2000, True), (2024, True), (2023, False), (2100, False), (1000, False)])
def test_is_leap(year, leap):
    assert dates.is_leap(year) is leap
    assert dates.year_length(year) == (366 if leap else 365)


def test_round_trip_every_day_1_to_10000():
    n = 0
    for year in range(1, 10001):
        for month in range(1, 13):
            for day in range(1, dates.month_length(year, month) + 1):
                assert dates.from_day_number(n) == (year, month, day)
                assert dates.to_day_number(year, month, day) == n
                n += 1


def test_matches_datetime_oracle():
    for ordinal in range(1, 3_652_059, 977):
        d = datetime.date.fromordinal(ordinal)
        n = ordinal - 1
        assert dates.from_day_number(n) == (d.year, d.month, d.day)
        assert n % 7 == d.weekday()


def test_last_day():
    assert dates.from_day_number(dates.LAST_DAY) == (9999, 12, 31)
