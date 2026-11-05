package query

import (
	"testing"

	"example.com/kvstore/value"
)

func p(s string) value.Path { return value.ParsePath(s) }

func TestEval(t *testing.T) {
	doc := value.NewObject([]value.Field{
		{Name: "age", Value: value.NewInt(36)},
		{Name: "name", Value: value.NewString("ada")},
		{Name: "tags", Value: value.NewList([]value.Value{value.NewInt(1)})},
		{Name: "n", Value: value.NewNull()},
	})
	cmp := func(path string, op Op, v value.Value) Node { return Cmp{Path: p(path), Op: op, Val: v} }
	tests := []struct {
		name string
		n    Node
		want bool
	}{
		{"eq", cmp("age", Eq, value.NewInt(36)), true},
		{"ne same", cmp("age", Ne, value.NewInt(36)), false},
		{"ne other rank", cmp("age", Ne, value.NewString("36")), true},
		{"lt other rank is false", cmp("age", Lt, value.NewString("z")), false},
		{"ge", cmp("age", Ge, value.NewInt(36)), true},
		{"string order", cmp("name", Gt, value.NewString("abc")), true},
		{"null le null", cmp("n", Le, value.NewNull()), true},
		{"null lt null", cmp("n", Lt, value.NewNull()), false},
		{"list eq", cmp("tags", Eq, value.NewList([]value.Value{value.NewInt(1)})), true},
		{"list order undefined", cmp("tags", Le, value.NewList(nil)), false},
		{"missing path: ne is false", cmp("zip", Ne, value.NewInt(1)), false},
		{"missing path: not is true", Not{cmp("zip", Eq, value.NewInt(1))}, true},
		{"exists", Exists{p("name")}, true},
		{"exists through scalar", Exists{p("age.x")}, false},
		{"missing", Missing{p("zip")}, true},
		{"through list is missing", Exists{p("tags.0")}, false},
		{"and/or", Or{cmp("age", Lt, value.NewInt(1)), And{Exists{p("age")}, Missing{p("q")}}}, true},
	}
	for _, tc := range tests {
		if got := Eval(tc.n, doc); got != tc.want {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestLeavesFlattenAnd(t *testing.T) {
	a, b, c := Exists{p("a")}, Exists{p("b")}, Exists{p("c")}
	got := Leaves(And{And{a, b}, c})
	if len(got) != 3 {
		t.Fatalf("%v", got)
	}
	for i, want := range []string{"a", "b", "c"} {
		if got[i].(Exists).Path.String() != want {
			t.Fatalf("leaf %d is %v, want %s", i, got[i], want)
		}
	}
	if got := Leaves(Or{a, b}); len(got) != 1 {
		t.Fatal("or is a leaf")
	}
}
