package jsoncanon

import "testing"

func TestParseAccessors(t *testing.T) {
	v, err := Parse([]byte(`{"a":[1,"x\n",true,null],"a2":1.5E+2,"k":1,"k":2}`))
	if err != nil {
		t.Fatal(err)
	}
	if v.Kind() != Object || v.Len() != 4 {
		t.Fatalf("kind=%v len=%d", v.Kind(), v.Len())
	}
	a := v.Lookup("a")
	if a == nil || a.Kind() != Array || a.Len() != 4 {
		t.Fatalf("bad a: %v", a)
	}
	if a.Elem(0).Num() != "1" || a.Elem(1).Str() != "x\n" || a.Elem(2).Kind() != True || a.Elem(3).Kind() != Null {
		t.Error("unexpected elements")
	}
	if got := v.Lookup("a2").Num(); got != "1.5e2" {
		t.Errorf("a2 = %q", got)
	}
	if got := v.Lookup("k").Num(); got != "2" {
		t.Errorf("k = %q, want last occurrence", got)
	}
	if v.Lookup("missing") != nil {
		t.Error("Lookup of missing key should be nil")
	}
	key, val := v.Member(3)
	if key != "k" || val.Num() != "2" {
		t.Errorf("Member(3) = %q, %v", key, val.Num())
	}
	if got := string(v.AppendCanonical(nil)); got != `{"a":[1,"x\n",true,null],"a2":1.5e2,"k":2}` {
		t.Errorf("canonical = %s", got)
	}
}

func TestSyntaxErrorOffset(t *testing.T) {
	_, err := Parse([]byte(`[1, x]`))
	se, ok := err.(*SyntaxError)
	if !ok || se.Offset != 4 {
		t.Fatalf("got %#v", err)
	}
	if se.Error() == "" {
		t.Error("empty message")
	}
}

func TestKindString(t *testing.T) {
	for k, want := range map[Kind]string{Null: "null", False: "false", True: "true", Number: "number", String: "string", Array: "array", Object: "object"} {
		if k.String() != want {
			t.Errorf("%d: %q", k, k.String())
		}
	}
}
