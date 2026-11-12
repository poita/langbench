package rrule

import "testing"

func TestIsLeapYear(t *testing.T) {
	for y, want := range map[int]bool{1900: false, 2000: true, 2023: false, 2024: true, 2100: false, 9996: true} {
		if got := IsLeapYear(y); got != want {
			t.Errorf("IsLeapYear(%d) = %v, want %v", y, got, want)
		}
	}
}

func TestAnchors(t *testing.T) {
	if got := daysFromCivil(1, 1, 1); got != 0 {
		t.Errorf("day number of 0001-01-01 = %d, want 0", got)
	}
	if got := weekdayOf(daysFromCivil(2000, 1, 1)); got != int(Saturday) {
		t.Errorf("2000-01-01 weekday = %d, want Saturday", got)
	}
	if got := weekdayOf(daysFromCivil(1997, 9, 2)); got != int(Tuesday) {
		t.Errorf("1997-09-02 weekday = %d, want Tuesday", got)
	}
}

func TestCivilRoundTrip(t *testing.T) {
	n := daysFromCivil(1000, 1, 1)
	end := daysFromCivil(10000, 1, 1)
	for y := 1000; y < 10000; y++ {
		for m := 1; m <= 12; m++ {
			for d := 1; d <= DaysInMonth(y, m); d++ {
				yy, mm, dd, yd := civilFromDays(n)
				if yy != y || mm != m || dd != d {
					t.Fatalf("day %d: got %d-%d-%d, want %d-%d-%d", n, yy, mm, dd, y, m, d)
				}
				if yd != n-daysFromYear(y) {
					t.Fatalf("day %d: yday %d", n, yd)
				}
				if daysFromCivil(y, m, d) != n {
					t.Fatalf("daysFromCivil(%d,%d,%d) != %d", y, m, d, n)
				}
				n++
			}
		}
	}
	if n != end {
		t.Fatalf("walked to %d, want %d", n, end)
	}
}

func TestWeekStartOffset(t *testing.T) {
	// 2011-01-01 is a Saturday: with WKST=MO week 1 starts on Monday 3 January.
	if got := weekStartOffset(2011, Monday); got != 2 {
		t.Errorf("s(2011) = %d, want 2", got)
	}
	// 2015-01-01 is a Thursday: week 1 starts on Monday 29 December 2014.
	if got := weekStartOffset(2015, Monday); got != -3 {
		t.Errorf("s(2015) = %d, want -3", got)
	}
	if got := weeksInYear(2015, -3); got != 53 {
		t.Errorf("weeks(2015) = %d, want 53", got)
	}
	if got := newWeekYear(2011, Monday).prev; got != 53 {
		t.Errorf("P(2011) = %d, want 53", got)
	}
	if got := newWeekYear(2012, Monday).prev; got != 52 {
		t.Errorf("P(2012) = %d, want 52", got)
	}
}
