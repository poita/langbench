package value

import (
	"testing"

	"example.com/template/tplerr"
)

func list(items ...Value) *List { return NewList(items) }

func dict(kv ...any) *Dict {
	d := NewDict(len(kv) / 2)
	for i := 0; i < len(kv); i += 2 {
		d.Set(kv[i].(string), kv[i+1])
	}
	return d
}

func kindOf(err error) tplerr.Kind {
	k, _ := tplerr.KindOf(err)
	return k
}

var point1, point2 = 0.1, 0.2
var sumPoint1Point2 = point1 + point2

func TestFormatFloat(t *testing.T) {
	tests := map[float64]string{
		0: "0.0", 3: "3.0", 0.5: "0.5", 1e15: "1000000000000000.0", 1e16: "1e+16",
		0.0001: "0.0001", 0.00001: "1e-05", sumPoint1Point2: "0.30000000000000004",
		1.5e300: "1.5e+300", -2.5: "-2.5", 123456.789: "123456.789", 1.0 / 3: "0.3333333333333333",
		12345678901234567890: "1.2345678901234567e+19",
	}
	for f, want := range tests {
		if got := FormatFloat(f); got != want {
			t.Errorf("FormatFloat(%v) = %q, want %q", f, got, want)
		}
	}
}

func TestToStringAndRepr(t *testing.T) {
	v := list(int64(1), "a", true, None, 1.5, "it's", dict("k", list(2.0)), "say \"hi\" it's", "a\\b\n\t")
	want := `[1, 'a', True, None, 1.5, "it's", {'k': [2.0]}, 'say "hi" it\'s', 'a\\b\n\t']`
	got, err := ToString(v)
	if err != nil || got != want {
		t.Errorf("ToString = %q, %v; want %q", got, err, want)
	}
	if s, _ := ToString(false); s != "False" {
		t.Errorf("ToString(false) = %q", s)
	}
	if s, _ := ToString(list()); s != "[]" {
		t.Errorf("empty list prints %q", s)
	}
	if _, err := ToString(Undefined); kindOf(err) != tplerr.Undefined {
		t.Errorf("printing undefined: got %v", err)
	}
}

func TestTruthy(t *testing.T) {
	falsy := []Value{false, None, int64(0), 0.0, "", list(), dict()}
	truthy := []Value{true, int64(-1), 0.1, "0", list(None), dict("a", None)}
	for _, v := range falsy {
		if b, err := Truthy(v); err != nil || b {
			t.Errorf("Truthy(%#v) = %v, %v; want false", v, b, err)
		}
	}
	for _, v := range truthy {
		if b, err := Truthy(v); err != nil || !b {
			t.Errorf("Truthy(%#v) = %v, %v; want true", v, b, err)
		}
	}
	if _, err := Truthy(Undefined); kindOf(err) != tplerr.Undefined {
		t.Errorf("Truthy(undefined): %v", err)
	}
}

func TestEqual(t *testing.T) {
	eq := [][2]Value{
		{int64(1), 1.0}, {true, int64(1)}, {"a", "a"}, {None, None},
		{list(int64(1), "x"), list(1.0, "x")},
		{dict("a", int64(1), "b", int64(2)), dict("b", int64(2), "a", int64(1))},
	}
	ne := [][2]Value{
		{int64(1), "1"}, {None, int64(0)}, {list(int64(1)), list(int64(1), int64(2))},
		{dict("a", int64(1)), dict("a", int64(2))}, {dict("a", None), dict("b", None)}, {"a", "b"},
	}
	for _, p := range eq {
		if !Equal(p[0], p[1]) {
			t.Errorf("Equal(%#v, %#v) = false", p[0], p[1])
		}
	}
	for _, p := range ne {
		if Equal(p[0], p[1]) {
			t.Errorf("Equal(%#v, %#v) = true", p[0], p[1])
		}
	}
}

func TestCompare(t *testing.T) {
	tests := []struct {
		op   CmpOp
		a, b Value
		want bool
	}{
		{CmpLt, int64(1), 1.5, true},
		{CmpGe, "b", "a", true},
		{CmpLt, "ab", "abc", true},
		{CmpLe, true, int64(1), true},
		{CmpIn, "b", "abc", true},
		{CmpIn, "", "abc", true},
		{CmpNotIn, "z", list("a"), true},
		{CmpIn, int64(1), list(1.0), true},
		{CmpIn, "k", dict("k", None), true},
		{CmpIn, int64(1), dict("1", None), false},
	}
	for _, tc := range tests {
		got, err := Compare(tc.op, tc.a, tc.b)
		if err != nil || got != tc.want {
			t.Errorf("Compare(%v, %#v, %#v) = %v, %v; want %v", tc.op, tc.a, tc.b, got, err, tc.want)
		}
	}
}

func TestCompareErrors(t *testing.T) {
	if _, err := Compare(CmpLt, "a", int64(1)); kindOf(err) != tplerr.Type {
		t.Errorf("string < int: %v", err)
	}
	if _, err := Compare(CmpIn, int64(1), "abc"); kindOf(err) != tplerr.Type {
		t.Errorf("int in string: %v", err)
	}
	if _, err := Compare(CmpIn, "a", None); kindOf(err) != tplerr.Type {
		t.Errorf("in none: %v", err)
	}
	if _, err := Compare(CmpEq, Undefined, int64(1)); kindOf(err) != tplerr.Undefined {
		t.Errorf("undefined == 1: %v", err)
	}
}

func TestBinary(t *testing.T) {
	tests := []struct {
		op   Op
		a, b Value
		want Value
	}{
		{OpAdd, int64(1), int64(2), int64(3)},
		{OpAdd, int64(1), 2.5, 3.5},
		{OpAdd, true, true, int64(2)},
		{OpAdd, "a", "b", "ab"},
		{OpSub, int64(1), 3.0, -2.0},
		{OpMul, "ab", int64(2), "abab"},
		{OpMul, int64(-1), "ab", ""},
		{OpDiv, int64(6), int64(3), 2.0},
		{OpFloorDiv, int64(-7), int64(2), int64(-4)},
		{OpFloorDiv, 7.0, int64(2), 3.0},
		{OpFloorDiv, int64(7), int64(-2), int64(-4)},
		{OpMod, int64(-7), int64(3), int64(2)},
		{OpMod, int64(7), int64(-3), int64(-2)},
		{OpMod, -7.5, int64(2), 0.5},
		{OpPow, int64(2), int64(10), int64(1024)},
		{OpPow, int64(2), int64(-1), 0.5},
		{OpPow, 2.0, int64(3), 8.0},
		{OpConcat, int64(1), "x", "1x"},
		{OpConcat, list(int64(1)), true, "[1]True"},
	}
	for _, tc := range tests {
		got, err := Binary(tc.op, tc.a, tc.b)
		if err != nil || got != tc.want {
			t.Errorf("Binary(%v, %#v, %#v) = %#v, %v; want %#v", tc.op, tc.a, tc.b, got, err, tc.want)
		}
	}
	got, err := Binary(OpAdd, list(int64(1)), list("a"))
	if s, _ := ToString(got); err != nil || s != "[1, 'a']" {
		t.Errorf("list + list = %v, %v", s, err)
	}
}

func TestBinaryErrors(t *testing.T) {
	typeErrs := [][3]Value{
		{OpAdd, "a", int64(1)}, {OpSub, "a", "b"}, {OpMul, "a", 1.5},
		{OpDiv, int64(1), int64(0)}, {OpFloorDiv, 1.0, 0.0}, {OpMod, int64(1), int64(0)},
		{OpPow, int64(0), int64(-1)}, {OpAdd, None, None},
	}
	for _, c := range typeErrs {
		if _, err := Binary(c[0].(Op), c[1], c[2]); kindOf(err) != tplerr.Type {
			t.Errorf("Binary(%v, %#v, %#v): got %v, want type error", c[0], c[1], c[2], err)
		}
	}
	if _, err := Binary(OpAdd, Undefined, int64(1)); kindOf(err) != tplerr.Undefined {
		t.Errorf("undefined + 1: %v", err)
	}
	if _, err := Neg("x"); kindOf(err) != tplerr.Type {
		t.Errorf("-'x': %v", err)
	}
}

func TestGetItem(t *testing.T) {
	l := list("a", "b", "c")
	tests := []struct {
		a, key, want Value
	}{
		{l, int64(0), "a"}, {l, int64(-1), "c"}, {l, int64(3), Undefined}, {l, int64(-4), Undefined},
		{l, "x", Undefined}, {l, 1.0, Undefined}, {l, true, "b"},
		{"héllo", int64(1), "é"}, {"héllo", int64(-1), "o"}, {"abc", int64(5), Undefined},
		{dict("k", int64(1)), "k", int64(1)}, {dict("k", int64(1)), "z", Undefined}, {dict("k", int64(1)), int64(0), Undefined},
		{None, "x", Undefined}, {int64(5), "x", Undefined},
		{&Loop{Index0: 1, Length: 3}, "index", int64(2)},
		{&Loop{Index0: 2, Length: 3}, "last", true},
	}
	for _, tc := range tests {
		got, err := GetItem(tc.a, tc.key)
		if err != nil || got != tc.want {
			t.Errorf("GetItem(%#v, %#v) = %#v, %v; want %#v", tc.a, tc.key, got, err, tc.want)
		}
	}
	if _, err := GetItem(Undefined, "x"); kindOf(err) != tplerr.Undefined {
		t.Errorf("undefined subscript: %v", err)
	}
	if _, err := GetAttr(Undefined, "x"); kindOf(err) != tplerr.Undefined {
		t.Errorf("undefined attribute: %v", err)
	}
}

func TestSeq(t *testing.T) {
	for _, tc := range []struct {
		v    Value
		want string
	}{
		{list(int64(1), "a"), "[1, 'a']"},
		{dict("x", int64(1), "y", int64(2)), "['x', 'y']"},
		{"hé", "['h', 'é']"},
	} {
		items, err := Seq(tc.v)
		if err != nil {
			t.Fatal(err)
		}
		if s, _ := ToString(NewList(items)); s != tc.want {
			t.Errorf("Seq(%#v) = %s, want %s", tc.v, s, tc.want)
		}
	}
	if _, err := Seq(int64(1)); kindOf(err) != tplerr.Type {
		t.Errorf("Seq(int): %v", err)
	}
	if _, err := Seq(Undefined); kindOf(err) != tplerr.Undefined {
		t.Errorf("Seq(undefined): %v", err)
	}
}

func TestDictOrderAndGrowth(t *testing.T) {
	d := NewDict(0)
	for i := 0; i < 30; i++ {
		d.Set(string(rune('a'+i)), int64(i))
	}
	d.Set("c", "replaced")
	if d.Len() != 30 || d.Keys()[2] != "c" {
		t.Fatalf("len %d keys %v", d.Len(), d.Keys())
	}
	if v, _ := d.Get("c"); v != "replaced" {
		t.Errorf("c = %v", v)
	}
	if v, ok := d.Get(string(rune('a' + 29))); !ok || v != int64(29) {
		t.Errorf("last = %v, %v", v, ok)
	}
	if _, ok := d.Get("nope"); ok {
		t.Error("found a missing key")
	}
}

func TestFromGo(t *testing.T) {
	v, err := FromGo(map[string]any{"b": []any{1, "x", nil, 2.5, true}, "a": int64(3), "t": []string{"p"}})
	if err != nil {
		t.Fatal(err)
	}
	if s, _ := ToString(v); s != "{'a': 3, 'b': [1, 'x', None, 2.5, True], 't': ['p']}" {
		t.Errorf("got %s", s)
	}
	if _, err := FromGo(struct{}{}); kindOf(err) != tplerr.Type {
		t.Errorf("struct: %v", err)
	}
}
