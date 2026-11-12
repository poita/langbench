package filters

import (
	"testing"

	"example.com/template/tplerr"
	"example.com/template/value"
)

func list(items ...value.Value) *value.List { return value.NewList(items) }

func show(t *testing.T, v value.Value) string {
	t.Helper()
	s, err := value.Repr(v)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestApply(t *testing.T) {
	d := value.NewDict(2)
	d.Set("b", int64(1))
	d.Set("a", int64(2))
	tests := []struct {
		name string
		in   value.Value
		args []value.Value
		want string
	}{
		{"upper", "Hello, wörld", nil, `'HELLO, WöRLD'`},
		{"lower", "HeLLo", nil, `'hello'`},
		{"upper", int64(5), nil, `'5'`},
		{"trim", " \t\n x y \r\f\v", nil, `'x y'`},
		{"escape", `<a href="x">'&amp;'</a>`, nil, `'&lt;a href=&#34;x&#34;&gt;&#39;&amp;amp;&#39;&lt;/a&gt;'`},
		{"replace", "aaa", []value.Value{"aa", "b"}, `'ba'`},
		{"replace", int64(1212), []value.Value{int64(1), "x"}, `'x2x2'`},
		{"length", "héllo", nil, `5`},
		{"length", list(int64(1), int64(2)), nil, `2`},
		{"length", d, nil, `2`},
		{"int", 3.9, nil, `3`},
		{"int", -3.9, nil, `-3`},
		{"int", true, nil, `1`},
		{"int", " +42 ", nil, `42`},
		{"int", "-3.7", nil, `-3`},
		{"int", "1e3", nil, `1000`},
		{"int", "5.", nil, `5`},
		{"int", ".5", nil, `0`},
		{"int", "12abc", nil, `0`},
		{"int", "", nil, `0`},
		{"int", value.None, nil, `0`},
		{"int", list(), nil, `0`},
		{"join", list(int64(1), "a", value.None), []value.Value{"-"}, `'1-a-None'`},
		{"join", "abc", nil, `'abc'`},
		{"join", d, []value.Value{","}, `'b,a'`},
		{"first", list(int64(7), int64(8)), nil, `7`},
		{"last", "abc", nil, `'c'`},
		{"first", d, nil, `'b'`},
		{"reverse", "abc", nil, `'cba'`},
		{"reverse", list(int64(1), int64(2), int64(3)), nil, `[3, 2, 1]`},
		{"reverse", d, nil, `['a', 'b']`},
		{"sort", list(int64(3), 1.5, true, int64(2)), nil, `[True, 1.5, 2, 3]`},
		{"sort", list("b", "A", "a", "B"), nil, `['A', 'a', 'b', 'B']`},
		{"sort", "cab", nil, `['a', 'b', 'c']`},
		{"sort", list(), nil, `[]`},
		{"default", value.Undefined, nil, `''`},
		{"default", value.Undefined, []value.Value{int64(4)}, `4`},
		{"default", value.None, []value.Value{int64(4)}, `None`},
		{"default", "", []value.Value{int64(4)}, `''`},
	}
	for _, tc := range tests {
		got, err := Apply(tc.name, tc.in, tc.args)
		if err != nil {
			t.Errorf("%s(%#v, %v): %v", tc.name, tc.in, tc.args, err)
			continue
		}
		if s := show(t, got); s != tc.want {
			t.Errorf("%s(%#v, %v) = %s, want %s", tc.name, tc.in, tc.args, s, tc.want)
		}
	}
}

func TestFirstLastEmptyAreUndefined(t *testing.T) {
	for _, name := range []string{"first", "last"} {
		v, err := Apply(name, list(), nil)
		if err != nil || !value.IsUndefined(v) {
			t.Errorf("%s([]) = %#v, %v", name, v, err)
		}
	}
}

func TestSortIsStable(t *testing.T) {
	// "b" and "B" share a key and must keep their original order.
	got, _ := Apply("sort", list("B", "b", "a"), nil)
	if s := show(t, got); s != `['a', 'B', 'b']` {
		t.Errorf("got %s", s)
	}
}

func TestErrors(t *testing.T) {
	tests := []struct {
		name string
		in   value.Value
		args []value.Value
		want tplerr.Kind
	}{
		{"nope", "x", nil, tplerr.Filter},
		{"upper", value.Undefined, nil, tplerr.Undefined},
		{"upper", value.Undefined, []value.Value{int64(1)}, tplerr.Undefined}, // undefined wins over arity
		{"upper", "x", []value.Value{int64(1)}, tplerr.Type},
		{"default", value.Undefined, []value.Value{int64(1), int64(2)}, tplerr.Type},
		{"replace", "x", []value.Value{"a"}, tplerr.Type},
		{"length", int64(5), nil, tplerr.Type},
		{"join", int64(5), nil, tplerr.Type},
		{"join", list(int64(1)), []value.Value{value.Undefined}, tplerr.Undefined},
		{"sort", list(int64(1), "a"), nil, tplerr.Type},
		{"sort", list(list()), nil, tplerr.Type},
		{"reverse", value.None, nil, tplerr.Type},
		{"first", int64(1), nil, tplerr.Type},
	}
	for _, tc := range tests {
		_, err := Apply(tc.name, tc.in, tc.args)
		if k, _ := tplerr.KindOf(err); k != tc.want {
			t.Errorf("%s(%#v, %v): got %v, want kind %s", tc.name, tc.in, tc.args, err, tc.want)
		}
	}
}

func TestNames(t *testing.T) {
	names := Names()
	if len(names) != 13 {
		t.Fatalf("got %d filters: %v", len(names), names)
	}
	for _, n := range names {
		if !Has(n) {
			t.Errorf("Has(%q) = false", n)
		}
	}
	if Has("items") {
		t.Error("Has(items) = true")
	}
}
