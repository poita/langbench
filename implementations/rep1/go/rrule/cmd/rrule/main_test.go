package main

import "testing"

func TestProcess(t *testing.T) {
	in := "19970902T090000 FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4 4\n" +
		"20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5 10\n" +
		"20240229T120000 FREQ=YEARLY;COUNT=3 2" // no final newline
	want := "19970902T090000 19970907T090000 19970916T090000 19970921T090000\n\n20240229T120000 20280229T120000\n"
	got, err := process([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
}

func TestProcessErrors(t *testing.T) {
	for _, in := range []string{"garbage\n", "20240101T000000 FREQ=NOPE 1\n", "20240101T000000 FREQ=DAILY x\n", "2024 FREQ=DAILY 1\n"} {
		if _, err := process([]byte(in)); err == nil {
			t.Errorf("process(%q) succeeded", in)
		}
	}
}
