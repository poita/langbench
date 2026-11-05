package rrule_test

import (
	"errors"
	"reflect"
	"testing"

	"github.com/example/rrule"
)

func TestParseRule(t *testing.T) {
	r, err := rrule.ParseRule("FREQ=YEARLY;INTERVAL=3;UNTIL=20300101T000000;WKST=SU;BYMONTH=1,7;" +
		"BYMONTHDAY=1,-1;BYYEARDAY=100,-5;BYDAY=2MO,-1FR;BYSETPOS=1,-2")
	if err != nil {
		t.Fatal(err)
	}
	if r.Freq != rrule.Yearly || r.Interval != 3 || r.WeekStart != rrule.Sunday || r.Count != 0 {
		t.Errorf("scalars: %+v", r)
	}
	if r.Until == nil || *r.Until != (rrule.DateTime{2030, 1, 1, 0, 0, 0}) {
		t.Errorf("until: %v", r.Until)
	}
	if !reflect.DeepEqual(r.ByMonth, []int{1, 7}) || !reflect.DeepEqual(r.ByMonthDay, []int{1, -1}) ||
		!reflect.DeepEqual(r.ByYearDay, []int{100, -5}) ||
		!reflect.DeepEqual(r.BySetPos, []int{1, -2}) {
		t.Errorf("lists: %+v", r)
	}
	want := []rrule.WeekdayNum{{2, rrule.Monday}, {-1, rrule.Friday}}
	if !reflect.DeepEqual(r.ByDay, want) {
		t.Errorf("ByDay = %v, want %v", r.ByDay, want)
	}
}

func TestParseRuleErrors(t *testing.T) {
	bad := []string{
		"",
		"INTERVAL=2",
		"FREQ=HOURLY",
		"FREQ=DAILY;FREQ=DAILY",
		"FREQ=DAILY;FOO=1",
		"FREQ=DAILY;COUNT",
		"FREQ=DAILY;COUNT=x",
		"FREQ=DAILY;INTERVAL=101",
		"FREQ=DAILY;COUNT=2;UNTIL=20200101T000000",
		"FREQ=DAILY;BYMONTH=13",
		"FREQ=DAILY;BYMONTHDAY=0",
		"FREQ=DAILY;BYYEARDAY=1",
		"FREQ=MONTHLY;BYWEEKNO=1",
		"FREQ=WEEKLY;BYDAY=1MO",
		"FREQ=MONTHLY;BYDAY=MO,1TU",
		"FREQ=MONTHLY;BYDAY=6MO",
		"FREQ=YEARLY;BYMONTH=1;BYDAY=6MO",
		"FREQ=YEARLY;BYWEEKNO=1;BYDAY=1MO",
		"FREQ=DAILY;BYDAY=XX",
		"FREQ=DAILY;WKST=ZZ",
		"FREQ=DAILY;UNTIL=2020",
	}
	for _, s := range bad {
		if _, err := rrule.ParseRule(s); !errors.Is(err, rrule.ErrInvalidRule) {
			t.Errorf("ParseRule(%q) err = %v, want ErrInvalidRule", s, err)
		}
	}
}

func TestYearlyOrdinalRange(t *testing.T) {
	if _, err := rrule.ParseRule("FREQ=YEARLY;BYDAY=53FR"); err != nil {
		t.Errorf("53FR without BYMONTH: %v", err)
	}
}
