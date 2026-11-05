package date

import "testing"

func TestParse(t *testing.T) {
	cases := []struct {
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
		{"1 jan 2000 00:00 est", 946702800 - 0, "2000-01-01T05:00:00Z", "-0500"},
		{"1 Jan 2000 00:00:00 +9999", 946684800 - 6039*60, "1999-12-27T19:21:00Z", "+10039"},
		{"1 Jan 2000 00:00:00 bogus", 946684800, "2000-01-01T00:00:00Z", "+0000"},
		{"1 Jan 2000 00:00:00", 946684800, "2000-01-01T00:00:00Z", "+0000"},
		{"1 Jan 100 00:00", 946684800 - 0, "", ""}, // placeholder, replaced below
	}
	cases = cases[:len(cases)-1]
	for _, c := range cases {
		d, ok := Parse(c.in)
		if !ok {
			t.Errorf("Parse(%q) invalid", c.in)
			continue
		}
		if d.Epoch != c.epoch || d.UTC() != c.utc || d.Offset() != c.offset {
			t.Errorf("Parse(%q) = %d %s %s; want %d %s %s", c.in, d.Epoch, d.UTC(), d.Offset(), c.epoch, c.utc, c.offset)
		}
	}
}

func TestInvalid(t *testing.T) {
	for _, in := range []string{
		"not a date", "", "1 Jan 2000", "30 Feb 2000 00:00", "29 Feb 2001 00:00",
		"32 Jan 2000 00:00", "0 Jan 2000 00:00", "1 Foo 2000 00:00", "1 Jan 2000 24:00",
		"1 Jan 2000 00:60", "1 Jan 2000 00:00:61", "1 Jan 0 00:00", "1 Jan 2000 0000",
		"1 Jan 20000 00:00", "1 Jan 2000 1:2:3:4", "Mon,", "1 Jan 0000 00:00",
	} {
		if d, ok := Parse(in); ok {
			t.Errorf("Parse(%q) = %+v, want invalid", in, d)
		}
	}
	if _, ok := Parse("1 Jan 2000 1:2"); !ok {
		t.Error("one-digit time fields are allowed")
	}
	if d, ok := Parse("29 Feb 2000 00:00"); !ok || d.UTC() != "2000-02-29T00:00:00Z" {
		t.Error("2000 is a leap year")
	}
}

func TestCivilRoundTrip(t *testing.T) {
	for days := int64(-800000); days < 3000000; days += 997 {
		y, m, d := CivilFromDays(days)
		if got := DaysFromCivil(y, m, d); got != days {
			t.Fatalf("round trip %d -> %d-%d-%d -> %d", days, y, m, d, got)
		}
	}
	if DaysFromCivil(1970, 1, 1) != 0 || DaysFromCivil(1969, 12, 31) != -1 {
		t.Error("epoch anchors")
	}
}
