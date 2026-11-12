package rrule

import (
	"reflect"
	"testing"
)

func TestParseDateTime(t *testing.T) {
	got, err := ParseDateTime("19970902T090507")
	if err != nil {
		t.Fatal(err)
	}
	want := DateTime{1997, 9, 2, 9, 5, 7}
	if got != want {
		t.Errorf("got %+v, want %+v", got, want)
	}
	if s := got.String(); s != "19970902T090507" {
		t.Errorf("String() = %q", s)
	}
	for _, bad := range []string{"", "19970902", "19970230T000000", "19970902T240000", "1997090 T000000", "19970902X000000"} {
		if _, err := ParseDateTime(bad); err == nil {
			t.Errorf("ParseDateTime(%q) succeeded, want error", bad)
		}
	}
}

func TestParseRule(t *testing.T) {
	got, err := ParseRule("FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR,2MO;WKST=SU;BYSETPOS=1,-1;UNTIL=19981231T000000")
	if err != nil {
		t.Fatal(err)
	}
	want := Rule{
		Freq: Monthly, Interval: 2, WeekStart: Sunday,
		HasUntil: true, Until: DateTime{1998, 12, 31, 0, 0, 0},
		ByDay:    []WeekdaySpec{{-1, Friday}, {2, Monday}},
		BySetPos: []int{1, -1},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v, want %+v", got, want)
	}
}

func TestParseRuleErrors(t *testing.T) {
	for _, bad := range []string{
		"",
		"INTERVAL=2",
		"FREQ=HOURLY",
		"FREQ=DAILY;FREQ=DAILY",
		"FREQ=DAILY;COUNT=3;UNTIL=20000101T000000",
		"FREQ=DAILY;BYMONTH=13",
		"FREQ=DAILY;BYMONTH=-1",
		"FREQ=MONTHLY;BYYEARDAY=3",
		"FREQ=WEEKLY;BYWEEKNO=3",
		"FREQ=WEEKLY;BYDAY=2MO",
		"FREQ=MONTHLY;BYDAY=MO,2TU",
		"FREQ=MONTHLY;BYDAY=6MO",
		"FREQ=YEARLY;BYWEEKNO=1;BYDAY=1MO",
		"FREQ=DAILY;BYDAY=XX",
		"FREQ=DAILY;FOO=1",
		"FREQ=DAILY;INTERVAL=0",
		"FREQ=DAILY;COUNT=0",
		"FREQ=DAILY;WKST=XX",
	} {
		if _, err := ParseRule(bad); err == nil {
			t.Errorf("ParseRule(%q) succeeded, want error", bad)
		}
	}
}

func TestWeekdaySpecString(t *testing.T) {
	if s := (WeekdaySpec{-1, Friday}).String(); s != "-1FR" {
		t.Errorf("got %q", s)
	}
	if s := (WeekdaySpec{0, Sunday}).String(); s != "SU" {
		t.Errorf("got %q", s)
	}
}
