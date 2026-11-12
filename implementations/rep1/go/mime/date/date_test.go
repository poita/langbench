package date

import "testing"

func TestParse(t *testing.T) {
	tests := []struct {
		in     string
		epoch  int64
		utc    string
		offset string
	}{
		{"Sun, 29 Feb 2004 22:03:22 -0800", 1078121002, "2004-03-01T06:03:22Z", "-0800"},
		{"3 Jan 70 00:00:00 GMT", 172800, "1970-01-03T00:00:00Z", "+0000"},
		{"Tue, 1 Jan 2036 00:00:60 +0000", 2082758460, "2036-01-01T00:01:00Z", "+0000"},
		{"Mon, 3 Mar 1969 12:00 (GMT) -0500", -26204400, "1969-03-03T17:00:00Z", "-0500"},
		{"Sun, 07 Mar 2004 15:21:26 -0000", 1078672886, "2004-03-07T15:21:26Z", "+0000"},
		{"1 Jan 2000 00:00:00 +2359", 946598460, "1999-12-31T00:01:00Z", "+2359"},
		{"1 Jan 2000 00:00 +9999", 946684800 - 6039*60, "1999-12-27T19:21:00Z", "+10039"},
		{"1 jan 2000 10:00 EST", 946738800, "2000-01-01T15:00:00Z", "-0500"},
		{"1 Jan 2000 10:00 bogus", 946720800, "2000-01-01T10:00:00Z", "+0000"},
		{"1 Jan 2000 10:00", 946720800, "2000-01-01T10:00:00Z", "+0000"},
	}
	for _, tc := range tests {
		d, ok := Parse(tc.in)
		if !ok {
			t.Errorf("Parse(%q) invalid", tc.in)
			continue
		}
		if d.Epoch != tc.epoch || d.UTC() != tc.utc || d.Offset() != tc.offset {
			t.Errorf("Parse(%q) = %d %s %s, want %d %s %s", tc.in, d.Epoch, d.UTC(), d.Offset(), tc.epoch, tc.utc, tc.offset)
		}
	}
}

func TestInvalid(t *testing.T) {
	for _, in := range []string{
		"not a date", "", "1 Jan 2000", "32 Jan 2000 00:00", "0 Jan 2000 00:00",
		"1 Foo 2000 00:00", "1 January 2000 00:00", "1 Jan 2000 24:00", "1 Jan 2000 00:60",
		"1 Jan 2000 00:00:61", "30 Feb 2000 00:00", "29 Feb 2001 00:00", "29 Feb 1900 00:00",
		"1 Jan 0000 00:00", "1 Jan 20000 00:00", "1 Jan 2000 0:0:0:0", "1 Jan 2000 000:00", "1 Jan 2000 1:",
	} {
		if d, ok := Parse(in); ok {
			t.Errorf("Parse(%q) = %+v, want invalid", in, d)
		}
	}
}

func TestTwoAndThreeDigitYears(t *testing.T) {
	for in, want := range map[string]string{
		"1 Jan 49 00:00":    "2049-01-01T00:00:00Z",
		"1 Jan 50 00:00":    "1950-01-01T00:00:00Z",
		"1 Jan 99 00:00":    "1999-01-01T00:00:00Z",
		"1 Jan 100 00:00":   "2000-01-01T00:00:00Z",
		"29 Feb 2000 00:00": "2000-02-29T00:00:00Z",
	} {
		d, ok := Parse(in)
		if !ok || d.UTC() != want {
			t.Errorf("Parse(%q) = %v %q, want %q", in, ok, d.UTC(), want)
		}
	}
}

func TestCivilRoundTrip(t *testing.T) {
	for days := int64(-800000); days < 3000000; days += 37 {
		y, m, d := CivilFromDays(days)
		if got := DaysFromCivil(y, m, d); got != days {
			t.Fatalf("round trip %d -> %d-%d-%d -> %d", days, y, m, d, got)
		}
	}
	if DaysFromCivil(1970, 1, 1) != 0 {
		t.Error("epoch day not 0")
	}
}
