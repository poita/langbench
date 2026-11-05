package jsonpointer

import (
	"reflect"
	"testing"

	"example.com/jsonschema/jsonvalue"
)

func TestTokens(t *testing.T) {
	tests := []struct {
		in   string
		want []string
		ok   bool
	}{
		{"", nil, true},
		{"/", []string{""}, true},
		{"/a/b", []string{"a", "b"}, true},
		{"/a~1b/c~0d", []string{"a/b", "c~d"}, true},
		{"/~01", []string{"~1"}, true},
		{"a", nil, false},
	}
	for _, tc := range tests {
		got, ok := Tokens(tc.in)
		if ok != tc.ok || !reflect.DeepEqual(got, tc.want) {
			t.Errorf("Tokens(%q) = %v, %v; want %v, %v", tc.in, got, ok, tc.want, tc.ok)
		}
	}
}

func TestResolve(t *testing.T) {
	root, err := jsonvalue.ParseString(`{"a":{"b":[10,20,{"c":true}]},"a/b":1,"m~n":2,"":3,"x":null}`)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		ptr  string
		kind jsonvalue.Kind
		ok   bool
	}{
		{"", jsonvalue.KindObject, true},
		{"/a", jsonvalue.KindObject, true},
		{"/a/b/1", jsonvalue.KindNumber, true},
		{"/a/b/2/c", jsonvalue.KindBool, true},
		{"/a~1b", jsonvalue.KindNumber, true},
		{"/m~0n", jsonvalue.KindNumber, true},
		{"/", jsonvalue.KindNumber, true},
		{"/x", jsonvalue.KindNull, true},
		{"/a/b/3", 0, false},
		{"/a/b/01", 0, false},
		{"/a/b/-", 0, false},
		{"/nope", 0, false},
		{"/a/b/0/z", 0, false},
		{"a", 0, false},
	}
	for _, tc := range tests {
		got := Resolve(&root, tc.ptr)
		if (got != nil) != tc.ok {
			t.Errorf("Resolve(%q) found=%v, want %v", tc.ptr, got != nil, tc.ok)
			continue
		}
		if got != nil && got.Kind() != tc.kind {
			t.Errorf("Resolve(%q) kind = %v, want %v", tc.ptr, got.Kind(), tc.kind)
		}
	}
	// Results are pointers into the tree, not copies.
	a := Resolve(&root, "/a")
	if a != root.Object().Get("a") {
		t.Error("Resolve must return a pointer into the tree")
	}
	if Resolve(&root, "") != &root {
		t.Error("empty pointer must return the root")
	}
}
