package value

import (
	"math"
	"testing"
)

func TestFormatReal(t *testing.T) {
	tests := []struct {
		in   float64
		want string
	}{
		{1.0, "1.0"}, {0.1, "0.1"}, {-3.25, "-3.25"}, {1.0 / 3, "0.333333333333333"},
		{1e300, "1.0e+300"}, {2.5e-10, "2.5e-10"}, {1.5e16, "1.5e+16"},
		{1e14, "100000000000000.0"}, {1e15, "1.0e+15"}, {0.0001, "0.0001"},
		{1e-5, "1.0e-05"}, {0, "0.0"}, {math.Copysign(0, -1), "0.0"},
		{123456.789, "123456.789"}, {-1e-7, "-1.0e-07"},
	}
	for _, tc := range tests {
		if got := FormatReal(tc.in); got != tc.want {
			t.Errorf("FormatReal(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestString(t *testing.T) {
	tests := []struct {
		v    Value
		want string
	}{
		{NullValue, "NULL"},
		{NewInt(-42), "-42"},
		{NewReal(2), "2.0"},
		{NewText("héllo"), "héllo"},
		{NewBlob([]byte{0, 0xab, 0x7f}), "00AB7F"},
		{NewBlob(nil), ""},
	}
	for _, tc := range tests {
		if got := tc.v.String(); got != tc.want {
			t.Errorf("%v.String() = %q, want %q", tc.v, got, tc.want)
		}
	}
}

func TestCompare(t *testing.T) {
	ordered := []Value{
		NullValue,
		NewReal(-1.5),
		NewInt(-1),
		NewInt(0),
		NewReal(0.5),
		NewInt(1),
		NewInt(math.MaxInt64 - 1),
		NewInt(math.MaxInt64),
		NewText(""),
		NewText("a"),
		NewText("ab"),
		NewText("b"),
		NewBlob(nil),
		NewBlob([]byte{0}),
		NewBlob([]byte{0xff}),
	}
	for i, a := range ordered {
		for j, b := range ordered {
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := Compare(a, b); got != want {
				t.Errorf("Compare(%v, %v) = %d, want %d", a, b, got, want)
			}
		}
	}
	if Compare(NewInt(2), NewReal(2)) != 0 {
		t.Error("2 and 2.0 should compare equal")
	}
	if Compare(NullValue, NullValue) != 0 {
		t.Error("two NULLs are equal")
	}
}

func TestAffinityOf(t *testing.T) {
	tests := map[string]Affinity{
		"INTEGER": AffinityInteger, "int": AffinityInteger, "BIGINT": AffinityInteger,
		"POINT": AffinityInteger, "FLOATING POINT": AffinityInteger, "INT TEXT": AffinityInteger,
		"NVARCHAR(160)": AffinityText, "CLOB": AffinityText, "CHAR FLOA": AffinityText,
		"BLOB": AffinityBlob, "": AffinityBlob, "BLOB REAL": AffinityBlob,
		"REAL": AffinityReal, "DOUBLE PRECISION": AffinityReal, "FLOAT": AffinityReal,
		"NUMERIC(10,2)": AffinityNumeric, "STRING": AffinityNumeric, "DATE": AffinityNumeric,
	}
	for in, want := range tests {
		if got := AffinityOf(in); got != want {
			t.Errorf("AffinityOf(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestParseNumericConstant(t *testing.T) {
	good := []struct {
		in   string
		want Value
	}{
		{"5", NewInt(5)}, {" 5 ", NewInt(5)}, {"\t-7\t", NewInt(-7)}, {"+5e0", NewReal(5)},
		{".5", NewReal(0.5)}, {"-.5", NewReal(-0.5)}, {"5.", NewReal(5)}, {"1.5e3", NewReal(1500)},
		{"9223372036854775807", NewInt(math.MaxInt64)},
		{"9223372036854775808", NewReal(9223372036854775808)},
		{"-9223372036854775808", NewInt(math.MinInt64)},
	}
	for _, tc := range good {
		got, ok := ParseNumericConstant(tc.in)
		if !ok || got != tc.want {
			t.Errorf("ParseNumericConstant(%q) = %v, %v; want %v", tc.in, got, ok, tc.want)
		}
	}
	for _, in := range []string{"", "-", ".", "0x10", "inf", "5 x", "1e", "1e+", "--5", "1 2", "e5"} {
		if v, ok := ParseNumericConstant(in); ok {
			t.Errorf("ParseNumericConstant(%q) = %v, want failure", in, v)
		}
	}
}

func TestApplyToLiteral(t *testing.T) {
	tests := []struct {
		aff  Affinity
		in   Value
		want Value
	}{
		{AffinityText, NewInt(5), NewText("5")},
		{AffinityText, NewReal(1), NewText("1.0")},
		{AffinityText, NewText("5"), NewText("5")},
		{AffinityInteger, NewText("12"), NewInt(12)},
		{AffinityReal, NewText(" 1.5 "), NewReal(1.5)},
		{AffinityNumeric, NewText("abc"), NewText("abc")},
		{AffinityBlob, NewText("12"), NewText("12")},
		{AffinityInteger, NullValue, NullValue},
		{AffinityInteger, NewBlob([]byte("1")), NewBlob([]byte("1"))},
	}
	for _, tc := range tests {
		if got := tc.aff.ApplyToLiteral(tc.in); got != tc.want {
			t.Errorf("%v.ApplyToLiteral(%v) = %v, want %v", tc.aff, tc.in, got, tc.want)
		}
	}
}
