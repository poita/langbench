package value_test

import (
	"testing"

	. "example.com/jq/value"
)

func obj(kv ...any) Value {
	o := NewObject(len(kv) / 2)
	for i := 0; i < len(kv); i += 2 {
		o.Set(kv[i].(string), kv[i+1].(Value))
	}
	return ObjectValue(o)
}

func arr(vs ...Value) Value { return Array(vs) }

func TestKindsAndTruthiness(t *testing.T) {
	cases := []struct {
		v      Value
		kind   Kind
		name   string
		truthy bool
	}{
		{Null, KindNull, "null", false},
		{False, KindFalse, "boolean", false},
		{True, KindTrue, "boolean", true},
		{Number(0), KindNumber, "number", true},
		{String(""), KindString, "string", true},
		{arr(), KindArray, "array", true},
		{obj(), KindObject, "object", true},
	}
	for _, c := range cases {
		if c.v.Kind() != c.kind || c.v.TypeName() != c.name || c.v.Truthy() != c.truthy {
			t.Errorf("%v: got kind %v name %q truthy %v", c.kind, c.v.Kind(), c.v.TypeName(), c.v.Truthy())
		}
	}
	var zero Value
	if !zero.IsNull() {
		t.Error("zero Value should be null")
	}
}

func TestAccessors(t *testing.T) {
	if Number(2.5).Float() != 2.5 || String("héllo").Str() != "héllo" {
		t.Error("scalar round trip failed")
	}
	a := arr(Number(1), Number(2))
	if len(a.Elems()) != 2 || a.Elems()[1].Float() != 2 {
		t.Error("array round trip failed")
	}
	if String("").Str() != "" || len(arr().Elems()) != 0 {
		t.Error("empty values")
	}
}

func TestCompareOrder(t *testing.T) {
	ordered := []Value{
		Null, False, True, Number(-1), Number(0), Number(1.5),
		String(""), String("a"), String("ab"), String("b"), String("Z" + "z"), String("é"),
		arr(), arr(Number(1)), arr(Number(1), Number(0)), arr(Number(2)),
		obj(), obj("a", Number(1)), obj("a", Number(2)), obj("a", Number(1), "b", Number(0)), obj("b", Number(0)),
	}
	// The list above is not fully sorted ("Zz" < "a"); sort-check pairs we know.
	ordered[10] = String("c")
	for i := range ordered {
		for j := range ordered {
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := Compare(ordered[i], ordered[j]); got != want {
				t.Errorf("Compare(#%d, #%d) = %d, want %d", i, j, got, want)
			}
		}
	}
}

func TestObjectEqualityIgnoresInsertionOrder(t *testing.T) {
	a := obj("a", Number(1), "b", Number(2))
	b := obj("b", Number(2), "a", Number(1))
	if !Equal(a, b) {
		t.Error("objects with the same members should be equal")
	}
	if Equal(a, obj("a", Number(1))) {
		t.Error("different key sets should differ")
	}
	if !Equal(Number(1), Number(1.5-0.5)) {
		t.Error("1 should equal 1.5-0.5")
	}
}

func TestObjectOrderAndSet(t *testing.T) {
	o := NewObject(0)
	o.Set("z", Number(1))
	o.Set("a", Number(2))
	o.Set("z", Number(3))
	es := o.Entries()
	if len(es) != 2 || es[0].Key != "z" || es[0].Val.Float() != 3 || es[1].Key != "a" {
		t.Errorf("unexpected entries %v", es)
	}
	keys := o.SortedKeys()
	if keys[0] != "a" || keys[1] != "z" {
		t.Errorf("sorted keys %v", keys)
	}
}

func TestLargeObjectUsesIndex(t *testing.T) {
	o := NewObject(0)
	for i := 0; i < 100; i++ {
		o.Set(string(rune('A'+i)), Number(float64(i)))
	}
	o.Set("A", Number(-1))
	if o.Len() != 100 {
		t.Fatalf("len %d", o.Len())
	}
	if v, ok := o.Get("A"); !ok || v.Float() != -1 {
		t.Error("overwrite via index failed")
	}
	if _, ok := o.Get("missing"); ok {
		t.Error("missing key found")
	}
}

func TestObjectFromEntriesDedupes(t *testing.T) {
	o := ObjectFromEntries([]Entry{{"a", Number(1)}, {"b", Number(2)}, {"a", Number(3)}})
	if o.Len() != 2 {
		t.Fatalf("len %d", o.Len())
	}
	if v, _ := o.Get("a"); v.Float() != 3 || o.Entries()[0].Key != "a" {
		t.Error("repeated key should keep first position and last value")
	}
}

func mustOK(v Value, err error) Value {
	if err != nil {
		panic(err)
	}
	return v
}

func TestAdd(t *testing.T) {
	if got := mustOK(Add(Null, Number(1))); got.Float() != 1 {
		t.Error("null + 1")
	}
	if got := mustOK(Add(String("a"), String("b"))); got.Str() != "ab" {
		t.Error("string concat")
	}
	if got := mustOK(Add(arr(Number(1)), arr(Number(2)))); len(got.Elems()) != 2 {
		t.Error("array concat")
	}
	got := mustOK(Add(obj("z", Number(1), "a", Number(2)), obj("m", Number(3), "z", Number(9))))
	es := got.Obj().Entries()
	if len(es) != 3 || es[0].Key != "z" || es[0].Val.Float() != 9 || es[1].Key != "a" || es[2].Key != "m" {
		t.Errorf("object merge order wrong: %v", es)
	}
	if _, err := Add(Number(1), String("a")); err == nil {
		t.Error("number + string should fail")
	}
	if _, err := Add(True, True); err == nil {
		t.Error("true + true should fail")
	}
}

func TestSubMulDivMod(t *testing.T) {
	if got := mustOK(Sub(arr(Number(1), Number(2), Number(1)), arr(Number(1)))); len(got.Elems()) != 1 {
		t.Error("array subtraction removes all occurrences")
	}
	if _, err := Sub(Null, Number(1)); err == nil {
		t.Error("null - 1 should fail")
	}
	if got := mustOK(Mul(String("ab"), Number(3))); got.Str() != "ababab" {
		t.Error("string repeat")
	}
	if got := mustOK(Mul(Number(0), String("ab"))); got.Str() != "" {
		t.Error("repeat zero")
	}
	if got := mustOK(Mul(String("ab"), Number(-1))); !got.IsNull() {
		t.Error("negative repeat is null")
	}
	merged := mustOK(Mul(
		obj("a", obj("x", Number(1), "y", Number(2)), "b", Number(1)),
		obj("a", obj("y", Number(3)), "b", obj("c", Number(1)))))
	a, _ := merged.Obj().Get("a")
	y, _ := a.Obj().Get("y")
	x, _ := a.Obj().Get("x")
	b, _ := merged.Obj().Get("b")
	if y.Float() != 3 || x.Float() != 1 || b.Kind() != KindObject {
		t.Error("deep merge")
	}
	if _, err := Div(Number(1), Number(0)); err == nil {
		t.Error("division by zero")
	}
	split := func(a, b string) []Value { return mustOK(Div(String(a), String(b))).Elems() }
	if len(split("a,b,,c", ",")) != 4 || len(split("", ",")) != 0 || len(split("abc", "")) != 3 {
		t.Error("string split")
	}
	for _, c := range []struct{ a, b, want float64 }{{-7, 3, -1}, {7, -3, 1}, {5.5, 2, 1}} {
		if got := mustOK(Mod(Number(c.a), Number(c.b))); got.Float() != c.want {
			t.Errorf("%v %% %v = %v, want %v", c.a, c.b, got.Float(), c.want)
		}
	}
	if _, err := Mod(Number(5), Number(0.5)); err == nil {
		t.Error("5 % 0.5 should fail")
	}
	if _, err := Neg(String("a")); err == nil {
		t.Error("negating a string should fail")
	}
}

func TestIndex(t *testing.T) {
	a := arr(Number(10), Number(20), Number(30))
	for _, c := range []struct {
		i    float64
		want float64
		null bool
	}{{0, 10, false}, {-1, 30, false}, {2.7, 30, false}, {3, 0, true}, {-4, 0, true}} {
		got := mustOK(Index(a, Number(c.i)))
		if c.null != got.IsNull() || (!c.null && got.Float() != c.want) {
			t.Errorf("index %v: got %v", c.i, got)
		}
	}
	if got := mustOK(Index(Null, String("a"))); !got.IsNull() {
		t.Error("null.a")
	}
	for _, c := range [][2]Value{
		{Number(5), String("a")}, {a, String("a")}, {obj(), Number(0)}, {Null, Null}, {a, Null},
	} {
		if _, err := Index(c[0], c[1]); err == nil {
			t.Errorf("Index(%s, %s) should fail", c[0].TypeName(), c[1].TypeName())
		}
	}
}

func TestSlice(t *testing.T) {
	a := arr(Number(0), Number(1), Number(2), Number(3))
	check := func(from, to Value, want int) {
		t.Helper()
		got := mustOK(Slice(a, from, to))
		if len(got.Elems()) != want {
			t.Errorf("slice length %d, want %d", len(got.Elems()), want)
		}
	}
	check(Number(1), Number(3), 2)
	check(Null, Number(-1), 3)
	check(Number(-2), Null, 2)
	check(Number(3), Number(1), 0)
	check(Number(-100), Number(100), 4)
	s := mustOK(Slice(String("aé😀bc"), Number(1), Number(3)))
	if s.Str() != "é😀" {
		t.Errorf("string slice = %q", s.Str())
	}
	if got := mustOK(Slice(String("aé😀"), Number(5), Null)); got.Str() != "" {
		t.Errorf("out of range string slice = %q", got.Str())
	}
	if got := mustOK(Slice(Null, Number(1), Null)); !got.IsNull() {
		t.Error("null slice")
	}
	if _, err := Slice(obj(), Null, Null); err == nil {
		t.Error("object slice should fail")
	}
}

func TestIterate(t *testing.T) {
	var got []float64
	err := Iterate(obj("b", Number(1), "a", Number(2)), func(v Value) error {
		got = append(got, v.Float())
		return nil
	})
	if err != nil || len(got) != 2 || got[0] != 1 || got[1] != 2 {
		t.Errorf("iterate object: %v %v", got, err)
	}
	if err := Iterate(Null, func(Value) error { return nil }); err == nil {
		t.Error("iterating null should fail")
	}
}
