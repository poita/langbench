package toml

import (
	"math"
	"testing"
)

func TestScalarText(t *testing.T) {
	tests := []struct {
		in   string
		kind Kind
		want string
	}{
		{"0", Integer, "0"},
		{"+17", Integer, "17"},
		{"-0", Integer, "0"},
		{"1_000", Integer, "1000"},
		{"0xDEAD_beef", Integer, "3735928559"},
		{"0o755", Integer, "493"},
		{"0b1101", Integer, "13"},
		{"0x0000000000000000000001", Integer, "1"},
		{"9223372036854775807", Integer, "9223372036854775807"},
		{"-9223372036854775808", Integer, "-9223372036854775808"},
		{"0x7FFFFFFFFFFFFFFF", Integer, "9223372036854775807"},
		{"1.0", Float, "1.0000000000000000e+00"},
		{"3.1415", Float, "3.1415000000000002e+00"},
		{"-0.0", Float, "-0.0000000000000000e+00"},
		{"0e0", Float, "0.0000000000000000e+00"},
		{"0e00", Float, "0.0000000000000000e+00"},
		{"1e308", Float, "1.0000000000000000e+308"},
		{"6.626e-34", Float, "6.6259999999999998e-34"},
		{"5e-324", Float, "4.9406564584124654e-324"},
		{"1e999", Float, "inf"},
		{"-1e999", Float, "-inf"},
		{"1e-999", Float, "0.0000000000000000e+00"},
		{"1_0.5_0e1_0", Float, "1.0500000000000000e+11"},
		{"inf", Float, "inf"},
		{"+inf", Float, "inf"},
		{"-inf", Float, "-inf"},
		{"nan", Float, "nan"},
		{"-nan", Float, "nan"},
		{"true", Bool, "true"},
		{"false", Bool, "false"},
		{"1979-05-27", DateLocal, "1979-05-27"},
		{"2024-02-29", DateLocal, "2024-02-29"},
		{"07:32:00", TimeLocal, "07:32:00"},
		{"07:32:00.500", TimeLocal, "07:32:00.5"},
		{"07:32:00.000", TimeLocal, "07:32:00"},
		{"07:32:00.123456789123", TimeLocal, "07:32:00.123456789123"},
		{"1979-05-27T07:32:00", DateTimeLocal, "1979-05-27T07:32:00"},
		{"1979-05-27t07:32:00", DateTimeLocal, "1979-05-27T07:32:00"},
		{"1979-05-27 07:32:00", DateTimeLocal, "1979-05-27T07:32:00"},
		{"1987-07-05 17:45:00z", DateTime, "1987-07-05T17:45:00Z"},
		{"1987-07-05T17:45:56.600+08:00", DateTime, "1987-07-05T17:45:56.6+08:00"},
		{"1979-05-27t07:32:00-00:00", DateTime, "1979-05-27T07:32:00Z"},
		{"1979-05-27T07:32:00+00:00", DateTime, "1979-05-27T07:32:00Z"},
		{"1979-05-27T07:32:00-08:30", DateTime, "1979-05-27T07:32:00-08:30"},
	}
	for _, tc := range tests {
		root, err := Parse([]byte("k = " + tc.in))
		if err != nil {
			t.Errorf("%s: %v", tc.in, err)
			continue
		}
		n, _ := root.Get("k")
		if n.Kind() != tc.kind || n.Text() != tc.want {
			t.Errorf("%s: got %v %q, want %v %q", tc.in, n.Kind(), n.Text(), tc.kind, tc.want)
		}
	}
}

func TestDateWithCommentIsLocalDate(t *testing.T) {
	root, err := Parse([]byte("d = 1979-05-27 # comment"))
	if err != nil {
		t.Fatal(err)
	}
	n, _ := root.Get("d")
	if n.Kind() != DateLocal {
		t.Errorf("kind = %v", n.Kind())
	}
}

func TestTypedAccessors(t *testing.T) {
	if v, ok := NewInt(-5).Int(); !ok || v != -5 {
		t.Errorf("Int = %v %v", v, ok)
	}
	if v, ok := NewFloat(2.5).Float(); !ok || v != 2.5 {
		t.Errorf("Float = %v %v", v, ok)
	}
	if v, ok := NewFloat(math.Inf(-1)).Float(); !ok || !math.IsInf(v, -1) {
		t.Errorf("-inf = %v %v", v, ok)
	}
	if v, ok := NewFloat(math.NaN()).Float(); !ok || !math.IsNaN(v) {
		t.Errorf("nan = %v %v", v, ok)
	}
	if v, ok := NewBool(true).Bool(); !ok || !v {
		t.Errorf("Bool = %v %v", v, ok)
	}
	if _, ok := NewString("x").Int(); ok {
		t.Error("Int on string succeeded")
	}
}

func TestFloatFormatMatchesPrintf(t *testing.T) {
	tests := map[float64]string{
		1:                           "1.0000000000000000e+00",
		123456789:                   "1.2345678900000000e+08",
		math.SmallestNonzeroFloat64: "4.9406564584124654e-324",
		math.MaxFloat64:             "1.7976931348623157e+308",
		-2.5e-7:                     "-2.4999999999999999e-07",
	}
	for v, want := range tests {
		if got := formatFloat(v); got != want {
			t.Errorf("formatFloat(%v) = %s, want %s", v, got, want)
		}
	}
}
