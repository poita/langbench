package minisql

import "testing"

func TestCompareOrder(t *testing.T) {
	ordered := []Value{Null(), Int(-5), Int(0), RealHundredths(150), Int(2), Text(""), Text("B"), Text("a"), Text("ab"), Text("b")}
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
	if Compare(Int(2), RealHundredths(200)) != 0 {
		t.Error("2 should equal 2.00")
	}
}

func TestValueString(t *testing.T) {
	cases := []struct {
		v    Value
		want string
	}{
		{Null(), "NULL"}, {Int(-12), "-12"}, {Text("hi"), "hi"},
		{RealHundredths(450), "4.50"}, {RealHundredths(-113), "-1.13"},
		{RealHundredths(0), "0.00"}, {RealHundredths(5), "0.05"},
	}
	for _, c := range cases {
		if got := c.v.String(); got != c.want {
			t.Errorf("String() = %q, want %q", got, c.want)
		}
	}
}

func TestKeyEncodingDistinguishesTypes(t *testing.T) {
	a := string(appendKey(nil, Int(1)))
	b := string(appendKey(nil, Text("1")))
	if a == b {
		t.Error("1 and '1' must have different keys")
	}
	x := string(appendKey(appendKey(nil, Text("ab")), Text("c")))
	y := string(appendKey(appendKey(nil, Text("a")), Text("bc")))
	if x == y {
		t.Error("composite keys must be unambiguous")
	}
}
