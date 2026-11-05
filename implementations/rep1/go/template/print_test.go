package template

import (
	"math"
	"testing"
)

func TestAppendFloat(t *testing.T) {
	for _, c := range []struct {
		f    float64
		want string
	}{
		{0, "0.0"}, {math.Copysign(0, -1), "-0.0"}, {1, "1.0"}, {-2.5, "-2.5"}, {0.5, "0.5"},
		{sumF(0.1, 0.2), "0.30000000000000004"}, {1e15, "1000000000000000.0"}, {1e16, "1e+16"},
		{123456789012345680, "1.2345678901234568e+17"}, {0.0001, "0.0001"}, {0.00001, "1e-05"},
		{1.5e300, "1.5e+300"}, {1e-7, "1e-07"}, {100, "100.0"}, {12345.678, "12345.678"},
		{5e-324, "5e-324"}, {1.7976931348623157e308, "1.7976931348623157e+308"},
	} {
		if got := string(appendFloat(nil, c.f)); got != c.want {
			t.Errorf("appendFloat(%v) = %q, want %q", c.f, got, c.want)
		}
	}
}

func sumF(a, b float64) float64 { return a + b }

func TestAppendQuoted(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"a", `'a'`}, {"it's", `"it's"`}, {`say "hi"`, `'say "hi"'`}, {`it's "x"`, `'it\'s "x"'`},
		{"a\\b", `'a\\b'`}, {"l1\nl2\r\t", `'l1\nl2\r\t'`}, {"", `''`},
	} {
		if got := string(appendQuoted(nil, c.in)); got != c.want {
			t.Errorf("appendQuoted(%q) = %s, want %s", c.in, got, c.want)
		}
	}
}

func TestFormat(t *testing.T) {
	d := NewDict(0)
	d.Set("k", NewList(int64(1), "x", true, None))
	got, err := Format(d)
	if err != nil || got != `{'k': [1, 'x', True, None]}` {
		t.Fatalf("Format = %q, %v", got, err)
	}
	if _, err := Format(Undefined); err == nil {
		t.Fatal("expected error for undefined")
	}
}
