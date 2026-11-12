package rrule

import (
	"fmt"
	"strings"
	"testing"
)

func expandString(t *testing.T, start, rule string, limit int) string {
	t.Helper()
	s, err := ParseDateTime(start)
	if err != nil {
		t.Fatal(err)
	}
	r, err := ParseRule(rule)
	if err != nil {
		t.Fatal(err)
	}
	ts, err := r.Expand(s, limit)
	if err != nil {
		t.Fatal(err)
	}
	parts := make([]string, len(ts))
	for i, x := range ts {
		parts[i] = x.String()
	}
	return strings.Join(parts, " ")
}

func TestExpand(t *testing.T) {
	tests := []struct {
		name, start, rule string
		limit             int
		want              string
	}{
		{"last friday every second month", "19970902T090000", "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=10", 100,
			"19970926T090000 19971128T090000 19980130T090000 19980327T090000 19980529T090000 19980731T090000 19980925T090000 19981127T090000 19990129T090000 19990326T090000"},
		{"weekly wkst su", "19970902T090000", "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH;COUNT=8", 100,
			"19970902T090000 19970904T090000 19970916T090000 19970918T090000 19970930T090000 19971002T090000 19971014T090000 19971016T090000"},
		{"weekly wkst mo", "19970902T090000", "FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4", 4,
			"19970902T090000 19970907T090000 19970916T090000 19970921T090000"},
		{"leap day yearly", "20240229T120000", "FREQ=YEARLY;COUNT=3", 10,
			"20240229T120000 20280229T120000 20320229T120000"},
		{"month end until", "20240131T000000", "FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240430T000000", 10,
			"20240131T000000 20240229T000000 20240331T000000 20240430T000000"},
		{"setpos last weekday", "20240301T080000", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3", 10,
			"20240329T080000 20240430T080000 20240531T080000"},
		{"feb 30 never", "20260101T000000", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5", 10, ""},
		{"week 53 mondays", "20200101T000000", "FREQ=YEARLY;BYWEEKNO=53;BYDAY=MO;COUNT=3", 10,
			"20201228T000000 20261228T000000 20321227T000000"},
		{"week 53 edge b", "20110101T000000", "FREQ=YEARLY;BYWEEKNO=53;COUNT=4", 10,
			"20110101T000000 20110102T000000 20151228T000000 20151229T000000"},
		{"setpos before dtstart", "20240120T100000", "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;COUNT=2", 10,
			"20240205T100000 20240304T100000"},
		{"setpos only", "20240115T000000", "FREQ=MONTHLY;BYSETPOS=1", 3,
			"20240115T000000 20240215T000000 20240315T000000"},
		{"setpos out of range", "20240115T000000", "FREQ=MONTHLY;BYSETPOS=2", 3, ""},
		{"until before dtstart", "20240115T000000", "FREQ=DAILY;UNTIL=20240114T000000", 3, ""},
		{"until inclusive", "20240115T000000", "FREQ=DAILY;UNTIL=20240117T000000", 10,
			"20240115T000000 20240116T000000 20240117T000000"},
		{"until time of day", "20240115T120000", "FREQ=DAILY;UNTIL=20240117T110000", 10,
			"20240115T120000 20240116T120000"},
		{"yearly ordinal with bymonth", "20240101T000000", "FREQ=YEARLY;BYMONTH=1,7;BYDAY=2MO;COUNT=4", 10,
			"20240108T000000 20240708T000000 20250113T000000 20250714T000000"},
		{"yearly ordinal whole year", "20240101T000000", "FREQ=YEARLY;BYDAY=-1MO;COUNT=2", 10,
			"20241230T000000 20251229T000000"},
		{"yearday negative", "20240101T000000", "FREQ=YEARLY;BYYEARDAY=-1,100;COUNT=3", 10,
			"20240409T000000 20241231T000000 20250410T000000"},
		{"daily interval", "20240101T000000", "FREQ=DAILY;INTERVAL=10", 3,
			"20240101T000000 20240111T000000 20240121T000000"},
		{"n limits", "20240101T000000", "FREQ=DAILY;COUNT=5", 2, "20240101T000000 20240102T000000"},
		{"year 9999 stops", "99991201T000000", "FREQ=DAILY", 100,
			func() string {
				var p []string
				for d := 1; d <= 31; d++ {
					p = append(p, fmt.Sprintf("999912%02dT000000", d))
				}
				return strings.Join(p, " ")
			}()},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := expandString(t, tc.start, tc.rule, tc.limit); got != tc.want {
				t.Errorf("got\n  %s\nwant\n  %s", got, tc.want)
			}
		})
	}
}

func TestEachStopsEarly(t *testing.T) {
	r, _ := ParseRule("FREQ=DAILY")
	n := 0
	err := r.Each(DateTime{2024, 1, 1, 0, 0, 0}, 0, func(DateTime) bool {
		n++
		return n < 3
	})
	if err != nil || n != 3 {
		t.Errorf("n=%d err=%v", n, err)
	}
}

func TestExpandInvalid(t *testing.T) {
	if _, err := (Rule{}).Expand(DateTime{2024, 1, 1, 0, 0, 0}, 1); err == nil {
		t.Error("zero Rule accepted")
	}
	r, _ := ParseRule("FREQ=DAILY")
	if _, err := r.Expand(DateTime{2024, 2, 30, 0, 0, 0}, 1); err == nil {
		t.Error("invalid DTSTART accepted")
	}
}

func BenchmarkSweepYearly(b *testing.B) {
	r, _ := ParseRule("FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30")
	start := DateTime{1000, 1, 1, 0, 0, 0}
	for i := 0; i < b.N; i++ {
		r.Expand(start, 10)
	}
}
