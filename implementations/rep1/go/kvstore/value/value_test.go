package value

import (
	"bytes"
	"testing"

	"example.com/kvstore/kverr"
)

func obj(fs ...Field) Value { return NewObject(fs) }

func TestSerializeWorkedExamples(t *testing.T) {
	v := obj(
		Field{"name", NewString("ada")},
		Field{"age", NewInt(36)},
		Field{"ok", NewBool(true)},
	)
	want := []byte{
		0x06, 0, 0, 0, 3,
		0, 0, 0, 3, 'a', 'g', 'e', 0x03, 0, 0, 0, 0, 0, 0, 0, 0x24,
		0, 0, 0, 4, 'n', 'a', 'm', 'e', 0x04, 0, 0, 0, 3, 'a', 'd', 'a',
		0, 0, 0, 2, 'o', 'k', 0x02,
	}
	if got := Serialize(v); !bytes.Equal(got, want) {
		t.Fatalf("Serialize = %x, want %x", got, want)
	}
	if got := Serialize(NewInt(-1)); !bytes.Equal(got, []byte{3, 255, 255, 255, 255, 255, 255, 255, 255}) {
		t.Fatalf("ser(-1) = %x", got)
	}
	if got := len(Serialize(NewList([]Value{NewInt(1), NewString("x"), NewNull()}))); got != 21 {
		t.Fatalf("list length %d, want 21", got)
	}
}

func TestRoundTrip(t *testing.T) {
	v := obj(
		Field{"a", NewList([]Value{NewNull(), NewBool(false), NewInt(-9223372036854775808)})},
		Field{"b", obj(Field{"c", NewString("é\x00😀")})},
		Field{"", NewList(nil)},
	)
	got, err := Deserialize(Serialize(v))
	if err != nil {
		t.Fatal(err)
	}
	if !Equal(v, got) {
		t.Fatalf("round trip changed value: %s vs %s", Render(v), Render(got))
	}
	if _, err := Deserialize([]byte{0x04, 0, 0, 0, 9, 'x'}); err == nil {
		t.Fatal("truncated string accepted")
	}
}

func TestRender(t *testing.T) {
	tests := []struct {
		v    Value
		want string
	}{
		{NewInt(-9223372036854775808), "-9223372036854775808"},
		{NewList([]Value{NewInt(1), NewString("x"), NewNull()}), `[1,"x",null]`},
		{obj(Field{"name", NewString("ada")}, Field{"age", NewInt(36)}), `{"age":36,"name":"ada"}`},
		{obj(), "{}"},
		{NewString("a\"b\\c/\b\t\n\f\r\x00\x1f\x7f é😀"), `"a\"b\\c/\b\t\n\f\r\u0000\u001f\u007f é😀"`},
	}
	for _, tc := range tests {
		if got := Render(tc.v); got != tc.want {
			t.Errorf("Render = %s, want %s", got, tc.want)
		}
	}
}

func TestDepth(t *testing.T) {
	if d := NewInt(1).Depth(); d != 1 {
		t.Fatal(d)
	}
	if d := NewList(nil).Depth(); d != 1 {
		t.Fatal(d)
	}
	v := NewList([]Value{obj(Field{"x", NewList([]Value{NewInt(1)})})})
	if d := v.Depth(); d != 4 {
		t.Fatalf("depth %d, want 4", d)
	}
}

func TestEqualAndCompare(t *testing.T) {
	a := obj(Field{"x", NewInt(1)}, Field{"y", NewInt(2)})
	b := obj(Field{"y", NewInt(2)}, Field{"x", NewInt(1)})
	if !Equal(a, b) {
		t.Error("objects differing in field order must be equal")
	}
	if Equal(NewInt(1), NewBool(true)) {
		t.Error("different kinds are never equal")
	}
	if c, ok := Compare(NewString("a"), NewString("b")); !ok || c != -1 {
		t.Error("string compare")
	}
	if c, ok := Compare(NewBool(false), NewBool(true)); !ok || c != -1 {
		t.Error("bool compare")
	}
	if _, ok := Compare(NewInt(1), NewString("1")); ok {
		t.Error("cross-kind compare must be undefined")
	}
	if _, ok := Compare(NewList(nil), NewList(nil)); ok {
		t.Error("lists are unordered")
	}
}

func TestPathOps(t *testing.T) {
	doc := obj(Field{"a", obj(Field{"b", NewInt(1)})}, Field{"l", NewList([]Value{NewInt(1)})})
	if v, ok := doc.Lookup(ParsePath("a.b")); !ok || v.Int != 1 {
		t.Error("lookup a.b")
	}
	if _, ok := doc.Lookup(ParsePath("l.0")); ok {
		t.Error("paths never traverse lists")
	}

	got, err := Set(doc, ParsePath("x.y.z"), NewInt(5))
	if err != nil {
		t.Fatal(err)
	}
	if r := Render(got); r != `{"a":{"b":1},"l":[1],"x":{"y":{"z":5}}}` {
		t.Errorf("auto-vivify: %s", r)
	}
	if _, err := Set(doc, ParsePath("l.q"), NewInt(1)); err != kverr.NotObject {
		t.Errorf("set through list: %v", err)
	}
	if _, err := Set(NewInt(1), ParsePath("q"), NewInt(1)); err != kverr.NotObject {
		t.Errorf("set on scalar: %v", err)
	}
	if Render(doc) != `{"a":{"b":1},"l":[1]}` {
		t.Error("Set modified its input")
	}

	if got, err := Unset(doc, ParsePath("a.b")); err != nil || Render(got) != `{"a":{},"l":[1]}` {
		t.Errorf("unset: %v %v", got, err)
	}
	if _, err := Unset(doc, ParsePath("a.c")); err != kverr.NoField {
		t.Errorf("unset missing: %v", err)
	}
	if _, err := Unset(doc, ParsePath("a.b.c")); err != kverr.NotObject {
		t.Errorf("unset through int: %v", err)
	}
}
