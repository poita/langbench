package sqlitefile

import (
	"math"
	"testing"
)

func TestAppendReal(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{
		{1.0, "1.0"}, {0.1, "0.1"}, {-3.25, "-3.25"}, {1.0 / 3, "0.333333333333333"},
		{1e300, "1.0e+300"}, {2.5e-10, "2.5e-10"}, {1.5e16, "1.5e+16"},
		{1e14, "100000000000000.0"}, {1e15, "1.0e+15"}, {0.0001, "0.0001"},
		{1e-5, "1.0e-05"}, {0.0, "0.0"}, {math.Copysign(0, -1), "0.0"},
		{123456.789, "123456.789"}, {-1e-7, "-1.0e-07"}, {12345678901234.5, "12345678901234.5"},
		{99999999999999.9, "99999999999999.9"}, {1.65, "1.65"}, {100, "100.0"},
		{1.5e100, "1.5e+100"}, {-2.5e-3, "-0.0025"}, {5e-324, "4.94065645841247e-324"},
	}
	for _, tc := range cases {
		if got := string(AppendReal(nil, tc.in)); got != tc.want {
			t.Errorf("AppendReal(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestAppendValue(t *testing.T) {
	cases := []struct {
		in   Value
		want string
	}{
		{Null(), "NULL"}, {Int(-42), "-42"}, {Int(math.MinInt64), "-9223372036854775808"},
		{Text("héllo"), "héllo"}, {Blob([]byte{0, 0xab, 0xff}), "00ABFF"}, {Blob(nil), ""},
		{Real(2), "2.0"},
	}
	for _, tc := range cases {
		if got := string(AppendValue(nil, tc.in)); got != tc.want {
			t.Errorf("AppendValue(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
	if got := string(AppendValue([]byte("x"), Int(1))); got != "x1" {
		t.Errorf("AppendValue must append, got %q", got)
	}
}
