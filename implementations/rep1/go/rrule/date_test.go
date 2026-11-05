package rrule

import "testing"

func TestIsLeapYear(t *testing.T) {
	for y, want := range map[int]bool{1000: false, 1900: false, 2000: true, 2023: false, 2024: true, 2100: false, 9996: true} {
		if got := IsLeapYear(y); got != want {
			t.Errorf("IsLeapYear(%d) = %v, want %v", y, got, want)
		}
	}
}

func TestDaysInMonth(t *testing.T) {
	cases := []struct{ y, m, want int }{{2023, 2, 28}, {2024, 2, 29}, {2024, 4, 30}, {2024, 12, 31}, {1900, 2, 28}}
	for _, c := range cases {
		if got := DaysInMonth(c.y, c.m); got != c.want {
			t.Errorf("DaysInMonth(%d,%d) = %d, want %d", c.y, c.m, got, c.want)
		}
	}
}

func TestAnchors(t *testing.T) {
	if got := DayOfWeek(2000, 1, 1); got != Saturday {
		t.Errorf("2000-01-01 = %v, want SA", got)
	}
	if got := DayOfWeek(1, 1, 1); got != Monday {
		t.Errorf("0001-01-01 = %v, want MO", got)
	}
	if got := dayNumber(1, 1, 1); got != 0 {
		t.Errorf("dayNumber(1,1,1) = %d", got)
	}
	if got := DayOfWeek(1997, 9, 2); got != Tuesday {
		t.Errorf("1997-09-02 = %v, want TU", got)
	}
}

// TestCivilRoundTrip checks the closed-form conversion against a naive
// day-by-day walk over several centuries, including century boundaries.
func TestCivilRoundTrip(t *testing.T) {
	n := dayNumber(1000, 1, 1)
	for y := 1000; y <= 2500; y++ {
		for m := 1; m <= 12; m++ {
			for d := 1; d <= DaysInMonth(y, m); d++ {
				if got := dayNumber(y, m, d); got != n {
					t.Fatalf("dayNumber(%d,%d,%d) = %d, want %d", y, m, d, got, n)
				}
				if gy, gm, gd := civilFromDay(n); gy != y || gm != m || gd != d {
					t.Fatalf("civilFromDay(%d) = %d-%d-%d, want %d-%d-%d", n, gy, gm, gd, y, m, d)
				}
				if n%7 != int(DayOfWeek(y, m, d)) {
					t.Fatalf("weekday mismatch")
				}
				n++
			}
		}
	}
	for _, y := range []int{3999, 4000, 9999, 10000} {
		if gy, gm, gd := civilFromDay(dayNumber(y, 12, 31)); gy != y || gm != 12 || gd != 31 {
			t.Errorf("round trip of %d-12-31 gave %d-%d-%d", y, gy, gm, gd)
		}
	}
}

func TestCursorAdvance(t *testing.T) {
	c := cursorAt(dayNumber(2023, 12, 30))
	for _, want := range [][3]int{{2023, 12, 31}, {2024, 1, 1}, {2024, 1, 2}} {
		c.advance()
		if c.year != want[0] || c.month != want[1] || c.dom != want[2] {
			t.Fatalf("cursor at %d-%d-%d, want %v", c.year, c.month, c.dom, want)
		}
	}
	if c.doy != 1 || c.ylen != 366 {
		t.Errorf("doy=%d ylen=%d", c.doy, c.ylen)
	}
}

func TestWeekInfo(t *testing.T) {
	// 2011 with WKST=MO: week 1 starts Monday 3 January; leading days get P=53.
	jan1 := dayNumber(2011, 1, 1)
	w := yearWeekInfo(0, jan1, 365, 365)
	if w.start != 2 || w.weeks != 52 || w.prev != 53 {
		t.Errorf("2011: %+v", w)
	}
	// 2015 has 53 weeks.
	jan1 = dayNumber(2015, 1, 1)
	if w := yearWeekInfo(0, jan1, 365, 365); w.weeks != 53 {
		t.Errorf("2015: %+v", w)
	}
	// 2012 starts on a Sunday: week 1 starts in the previous year, P = weeks(2011-ish) path.
	jan1 = dayNumber(2012, 1, 1)
	if w := yearWeekInfo(0, jan1, 366, 365); w.start != 1 || w.prev != 52 {
		t.Errorf("2012: %+v", w)
	}
}
