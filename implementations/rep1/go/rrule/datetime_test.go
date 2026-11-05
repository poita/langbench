package rrule_test

import (
	"errors"
	"testing"

	"github.com/example/rrule"
)

func TestParseDateTime(t *testing.T) {
	dt, err := rrule.ParseDateTime("19970902T090501")
	if err != nil {
		t.Fatal(err)
	}
	if dt != (rrule.DateTime{1997, 9, 2, 9, 5, 1}) {
		t.Errorf("got %+v", dt)
	}
	if dt.String() != "19970902T090501" {
		t.Errorf("String = %q", dt.String())
	}
	if dt.Weekday() != rrule.Tuesday {
		t.Errorf("Weekday = %v", dt.Weekday())
	}
}

func TestParseDateTimeErrors(t *testing.T) {
	for _, s := range []string{"", "19970902", "19970902 090000", "19970230T000000", "09990101T000000",
		"19970902T240000", "19970902T006000", "1997090aT000000", "19970902T0000000", "00000000T000000"} {
		if _, err := rrule.ParseDateTime(s); !errors.Is(err, rrule.ErrInvalidDateTime) {
			t.Errorf("ParseDateTime(%q) err = %v", s, err)
		}
	}
}

func TestCompare(t *testing.T) {
	a := rrule.DateTime{2020, 1, 1, 0, 0, 0}
	b := rrule.DateTime{2020, 1, 1, 0, 0, 1}
	if a.Compare(b) != -1 || b.Compare(a) != 1 || a.Compare(a) != 0 {
		t.Error("Compare misordered")
	}
}
