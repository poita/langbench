package rrule_test

import (
	"reflect"
	"strings"
	"testing"

	"github.com/example/rrule"
)

// expand runs one rule through the public API and returns the stamps.
func expand(t *testing.T, start, rule string, n int) []string {
	t.Helper()
	dt, err := rrule.ParseDateTime(start)
	if err != nil {
		t.Fatal(err)
	}
	r, err := rrule.ParseRule(rule)
	if err != nil {
		t.Fatal(err)
	}
	got, err := r.Expand(dt, n)
	if err != nil {
		t.Fatal(err)
	}
	out := []string{}
	for _, g := range got {
		out = append(out, g.String())
	}
	return out
}

func TestExpandCases(t *testing.T) {
	cases := []struct {
		name, start, rule string
		n                 int
		want              string // space-separated stamps
	}{
		{"last friday every 2 months", "19970902T090000", "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=10", 100,
			"19970926T090000 19971128T090000 19980130T090000 19980327T090000 19980529T090000 19980731T090000 19980925T090000 19981127T090000 19990129T090000 19990326T090000"},
		{"wkst su", "19970902T090000", "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH;COUNT=8", 100,
			"19970902T090000 19970904T090000 19970916T090000 19970918T090000 19970930T090000 19971002T090000 19971014T090000 19971016T090000"},
		{"wkst mo", "19970902T090000", "FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4", 4,
			"19970902T090000 19970907T090000 19970916T090000 19970921T090000"},
		{"leap day yearly", "20240229T120000", "FREQ=YEARLY;COUNT=3", 10,
			"20240229T120000 20280229T120000 20320229T120000"},
		{"month end until", "20240131T000000", "FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240430T000000", 10,
			"20240131T000000 20240229T000000 20240331T000000 20240430T000000"},
		{"last weekday setpos", "20240301T080000", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3", 10,
			"20240329T080000 20240430T080000 20240531T080000"},
		{"feb 30 never", "20260101T000000", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5", 10, ""},
		{"week 53 mondays", "20200101T000000", "FREQ=YEARLY;BYWEEKNO=53;BYDAY=MO;COUNT=3", 10,
			"20201228T000000 20261228T000000 20321227T000000"},
		{"week 53 leading days", "20110101T000000", "FREQ=YEARLY;BYWEEKNO=53;COUNT=4", 10,
			"20110101T000000 20110102T000000 20151228T000000 20151229T000000"},
		{"setpos discards before dtstart", "20240120T100000", "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;COUNT=2", 10,
			"20240205T100000 20240304T100000"},
		{"setpos only", "20240115T000000", "FREQ=MONTHLY;BYSETPOS=2;COUNT=3", 10, ""},
		{"setpos one default", "20240115T000000", "FREQ=MONTHLY;BYSETPOS=1;COUNT=2", 10,
			"20240115T000000 20240215T000000"},
		{"setpos duplicates", "20240101T000000", "FREQ=MONTHLY;BYDAY=MO,TU;BYSETPOS=1,-9,1,-9;COUNT=1", 10,
			"20240101T000000"},
		{"until before dtstart", "20240101T000000", "FREQ=DAILY;UNTIL=20231231T235959", 10, ""},
		{"until equals dtstart", "20240101T000000", "FREQ=DAILY;UNTIL=20240101T000000", 10, "20240101T000000"},
		{"until time of day", "20240101T120000", "FREQ=DAILY;UNTIL=20240103T115959", 10,
			"20240101T120000 20240102T120000"},
		{"limit n wins", "20240101T000000", "FREQ=DAILY;COUNT=10", 2, "20240101T000000 20240102T000000"},
		{"daily interval", "20240228T235959", "FREQ=DAILY;INTERVAL=2;COUNT=3", 9,
			"20240228T235959 20240301T235959 20240303T235959"},
		{"yearly ordinal with bymonth", "20240101T000000", "FREQ=YEARLY;BYMONTH=1,7;BYDAY=2MO;COUNT=4", 10,
			"20240108T000000 20240708T000000 20250113T000000 20250714T000000"},
		{"yearly ordinal whole year", "20240101T000000", "FREQ=YEARLY;BYDAY=20MO,-1SU;COUNT=3", 10,
			"20240513T000000 20241229T000000 20250519T000000"},
		{"fifth monday skips", "20240101T000000", "FREQ=MONTHLY;BYDAY=5MO;COUNT=3", 10,
			"20240129T000000 20240429T000000 20240729T000000"},
		{"yearday", "20240101T000000", "FREQ=YEARLY;BYYEARDAY=1,-1;COUNT=3", 10,
			"20240101T000000 20241231T000000 20250101T000000"},
		{"monthly 31st", "20240131T000000", "FREQ=MONTHLY;COUNT=4", 10,
			"20240131T000000 20240331T000000 20240531T000000 20240731T000000"},
		{"weekly default", "20240103T000000", "FREQ=WEEKLY;COUNT=3", 10,
			"20240103T000000 20240110T000000 20240117T000000"},
		{"weekly across year end", "20231229T000000", "FREQ=WEEKLY;BYDAY=FR,MO;COUNT=4", 10,
			"20231229T000000 20240101T000000 20240105T000000 20240108T000000"},
		{"week 1 trailing december days", "20241201T000000", "FREQ=YEARLY;BYWEEKNO=1;BYDAY=MO;COUNT=2", 10,
			"20241230T000000 20251229T000000"},
		{"negative weekno", "20240101T000000", "FREQ=YEARLY;BYWEEKNO=-1;BYDAY=SU;COUNT=2", 10,
			"20241229T000000 20251228T000000"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := strings.Join(expand(t, c.start, c.rule, c.n), " ")
			if got != c.want {
				t.Errorf("got  %s\nwant %s", got, c.want)
			}
		})
	}
}

func TestYear9999(t *testing.T) {
	got := expand(t, "99981101T000000", "FREQ=MONTHLY", 100)
	if len(got) != 14 || got[13] != "99991201T000000" {
		t.Errorf("monthly: %v", got)
	}
	got = expand(t, "99991230T000000", "FREQ=DAILY", 100)
	if !reflect.DeepEqual(got, []string{"99991230T000000", "99991231T000000"}) {
		t.Errorf("daily: %v", got)
	}
	got = expand(t, "99990101T000000", "FREQ=YEARLY;INTERVAL=2", 100)
	if len(got) != 1 {
		t.Errorf("yearly: %v", got)
	}
}

func TestExpandInvalidInputs(t *testing.T) {
	r := &rrule.Rule{Freq: rrule.Daily}
	if _, err := r.Expand(rrule.DateTime{Year: 999, Month: 1, Day: 1}, 1); err == nil {
		t.Error("expected error for invalid start")
	}
	if _, err := (&rrule.Rule{}).Expand(rrule.DateTime{Year: 2020, Month: 1, Day: 1}, 1); err == nil {
		t.Error("expected error for rule without FREQ")
	}
	if got, err := r.Expand(rrule.DateTime{Year: 2020, Month: 1, Day: 1}, 0); err != nil || len(got) != 0 {
		t.Errorf("n=0: %v %v", got, err)
	}
}

func TestEachStopsEarly(t *testing.T) {
	r, _ := rrule.ParseRule("FREQ=DAILY")
	start := rrule.DateTime{Year: 2020, Month: 1, Day: 1}
	var seen int
	err := rrule.NewExpander().Each(r, start, 1000, func(rrule.DateTime) bool { seen++; return seen < 3 })
	if err != nil || seen != 3 {
		t.Errorf("seen=%d err=%v", seen, err)
	}
}

func TestAppendTextReuse(t *testing.T) {
	e := rrule.NewExpander()
	start := rrule.DateTime{Year: 2020, Month: 2, Day: 28, Hour: 1, Minute: 2, Second: 3}
	var buf []byte
	r1, _ := rrule.ParseRule("FREQ=DAILY;COUNT=3")
	r2, _ := rrule.ParseRule("FREQ=MONTHLY;BYDAY=2MO;BYSETPOS=1;COUNT=1")
	buf, _ = e.AppendText(buf, r1, start, 10)
	buf = append(buf, '\n')
	buf, _ = e.AppendText(buf, r2, start, 10)
	want := "20200228T010203 20200229T010203 20200301T010203\n20200309T010203"
	if string(buf) != want {
		t.Errorf("got %q want %q", buf, want)
	}
}

// TestRulePurity ensures expansion does not mutate the rule.
func TestRulePurity(t *testing.T) {
	r, _ := rrule.ParseRule("FREQ=YEARLY;COUNT=2")
	before := *r
	r.Expand(rrule.DateTime{Year: 2020, Month: 3, Day: 4}, 5)
	if !reflect.DeepEqual(*r, before) {
		t.Errorf("rule mutated: %+v", r)
	}
}
