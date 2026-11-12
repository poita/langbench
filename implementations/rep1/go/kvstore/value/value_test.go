package value

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func hexOf(b []byte) string { return hex.EncodeToString(b) }

func TestSerializeWorkedExamples(t *testing.T) {
	obj := ObjectValue(
		Field{"name", StringValue("ada")},
		Field{"age", IntValue(36)},
		Field{"ok", BoolValue(true)},
	)
	tests := []struct {
		name string
		v    Value
		want string
	}{
		{"1", IntValue(1), "030000000000000001"},
		{"-1", IntValue(-1), "03ffffffffffffffff"},
		{"null", NullValue(), "00"},
		{"true", BoolValue(true), "02"},
		{"false", BoolValue(false), "01"},
		{"empty string", StringValue(""), "0400000000"},
		{"ada", StringValue("ada"), "040000000361" + "6461"},
		{"list", ListValue(IntValue(1), StringValue("x"), NullValue()),
			"0500000003" + "030000000000000001" + "040000000178" + "00"},
		{"object", obj, "0600000003" +
			"00000003616765" + "030000000000000024" +
			"000000046e616d65" + "040000000361" + "6461" +
			"000000026f6b" + "02"},
	}
	for _, tc := range tests {
		got := Serialize(tc.v)
		if hexOf(got) != tc.want {
			t.Errorf("%s: got %s, want %s", tc.name, hexOf(got), tc.want)
		}
		if SerializedLen(tc.v) != len(got) {
			t.Errorf("%s: SerializedLen = %d, want %d", tc.name, SerializedLen(tc.v), len(got))
		}
		back, err := Deserialize(got)
		if err != nil || !Equal(back, tc.v) {
			t.Errorf("%s: round trip failed: %v", tc.name, err)
		}
	}
	if n := len(Serialize(obj)); n != 44 {
		t.Errorf("object length = %d, want 44", n)
	}
}

func TestObjectFieldOrderIsCanonical(t *testing.T) {
	a := ObjectValue(Field{"b", IntValue(1)}, Field{"a", IntValue(2)})
	b := ObjectValue(Field{"a", IntValue(2)}, Field{"b", IntValue(1)})
	if !bytes.Equal(Serialize(a), Serialize(b)) || !Equal(a, b) {
		t.Fatal("field order must not matter")
	}
	if got := Render(a); got != `{"a":2,"b":1}` {
		t.Fatalf("render = %s", got)
	}
}

func TestRender(t *testing.T) {
	tests := []struct {
		v    Value
		want string
	}{
		{IntValue(-9223372036854775808), "-9223372036854775808"},
		{IntValue(0), "0"},
		{ListValue(), "[]"},
		{ObjectValue(), "{}"},
		{StringValue("a\"b\\c/d"), `"a\"b\\c/d"`},
		{StringValue("\b\t\n\f\r"), `"\b\t\n\f\r"`},
		{StringValue("\x00\x1f\x7f"), `"\u0000\u001f\u007f"`},
		{StringValue("é😀"), `"é😀"`},
		{ListValue(IntValue(1), StringValue("x"), NullValue()), `[1,"x",null]`},
	}
	for _, tc := range tests {
		if got := Render(tc.v); got != tc.want {
			t.Errorf("got %s, want %s", got, tc.want)
		}
	}
}

func TestVKey(t *testing.T) {
	tests := []struct {
		v    Value
		want string
	}{
		{NullValue(), "10"},
		{BoolValue(false), "20"},
		{BoolValue(true), "21"},
		{IntValue(0), "308000000000000000"},
		{IntValue(36), "308000000000000024"},
		{IntValue(-1), "307fffffffffffffff"},
		{IntValue(-9223372036854775808), "300000000000000000"},
		{IntValue(9223372036854775807), "30ffffffffffffffff"},
		{StringValue(""), "400000"},
		{StringValue("ada"), "406164610000"},
		{StringValue("a\x00b"), "4061" + "00ff" + "620000"},
	}
	for _, tc := range tests {
		got, ok := VKey(tc.v)
		if !ok || hexOf(got) != tc.want {
			t.Errorf("vkey(%s) = %s, want %s", Render(tc.v), hexOf(got), tc.want)
		}
		if VKeyLen(tc.v) != len(got) {
			t.Errorf("VKeyLen(%s) = %d, want %d", Render(tc.v), VKeyLen(tc.v), len(got))
		}
	}
	if _, ok := VKey(ListValue()); ok {
		t.Error("lists have no vkey")
	}
	if _, ok := VKey(ObjectValue()); ok {
		t.Error("objects have no vkey")
	}
}

func TestVKeyOrderPreserving(t *testing.T) {
	ordered := []Value{
		NullValue(), BoolValue(false), BoolValue(true),
		IntValue(-9223372036854775808), IntValue(-2), IntValue(-1), IntValue(0), IntValue(7),
		IntValue(9223372036854775807),
		StringValue(""), StringValue("\x00"), StringValue("\x00a"), StringValue("a"),
		StringValue("a\x00"), StringValue("ab"), StringValue("b"),
	}
	for i := 0; i+1 < len(ordered); i++ {
		a, _ := VKey(ordered[i])
		b, _ := VKey(ordered[i+1])
		if bytes.Compare(a, b) >= 0 {
			t.Errorf("vkey(%s) should sort before vkey(%s)", Render(ordered[i]), Render(ordered[i+1]))
		}
	}
}

func TestDepth(t *testing.T) {
	if d := IntValue(1).Depth(); d != 1 {
		t.Errorf("scalar depth = %d", d)
	}
	if d := ListValue().Depth(); d != 1 {
		t.Errorf("empty list depth = %d", d)
	}
	v := ListValue(ObjectValue(Field{"x", ListValue(IntValue(1))}))
	if d := v.Depth(); d != 4 {
		t.Errorf("depth = %d, want 4", d)
	}
}

func TestLookup(t *testing.T) {
	doc := ObjectValue(
		Field{"a", ObjectValue(Field{"b", IntValue(5)})},
		Field{"l", ListValue(IntValue(1))},
	)
	if v, ok := doc.Lookup([]string{"a", "b"}); !ok || v.I != 5 {
		t.Errorf("a.b = %v, %v", v, ok)
	}
	for _, p := range [][]string{{"x"}, {"a", "x"}, {"a", "b", "c"}, {"l", "0"}} {
		if _, ok := doc.Lookup(p); ok {
			t.Errorf("path %v should be missing", p)
		}
	}
}

func TestSetAndUnset(t *testing.T) {
	doc := ObjectValue(Field{"a", IntValue(1)})
	got, err := Set(doc, []string{"x", "y"}, IntValue(2))
	if err != nil || Render(got) != `{"a":1,"x":{"y":2}}` {
		t.Fatalf("Set = %s, %v", Render(got), err)
	}
	if Render(doc) != `{"a":1}` {
		t.Fatal("Set must not modify its input")
	}
	if _, err := Set(doc, []string{"a", "b"}, NullValue()); err != ErrNotObject {
		t.Errorf("want ErrNotObject, got %v", err)
	}
	if _, err := Set(IntValue(1), []string{"a"}, NullValue()); err != ErrNotObject {
		t.Errorf("want ErrNotObject, got %v", err)
	}
	got, err = Unset(got, []string{"x", "y"})
	if err != nil || Render(got) != `{"a":1,"x":{}}` {
		t.Fatalf("Unset = %s, %v", Render(got), err)
	}
	if _, err := Unset(got, []string{"zz"}); err != ErrNoField {
		t.Errorf("want ErrNoField, got %v", err)
	}
	if _, err := Unset(got, []string{"a", "b"}); err != ErrNotObject {
		t.Errorf("want ErrNotObject, got %v", err)
	}
}

func TestCompareAndEqual(t *testing.T) {
	if c, ok := Compare(IntValue(1), IntValue(2)); !ok || c != -1 {
		t.Error("1 < 2")
	}
	if c, ok := Compare(StringValue("b"), StringValue("a")); !ok || c != 1 {
		t.Error("b > a")
	}
	if c, ok := Compare(NullValue(), NullValue()); !ok || c != 0 {
		t.Error("null == null")
	}
	if _, ok := Compare(IntValue(1), StringValue("1")); ok {
		t.Error("different kinds are not ordered")
	}
	if _, ok := Compare(ListValue(), ListValue()); ok {
		t.Error("lists are not ordered")
	}
	if !Equal(ListValue(IntValue(1)), ListValue(IntValue(1))) || Equal(ListValue(IntValue(1)), ListValue()) {
		t.Error("list equality")
	}
	if Equal(IntValue(1), BoolValue(true)) {
		t.Error("1 != true")
	}
}

func TestDeserializeRejectsGarbage(t *testing.T) {
	for _, in := range []string{"", "07", "03000000", "0400000005ab", "050000000200", "00ff"} {
		b, _ := hex.DecodeString(in)
		if _, err := Deserialize(b); err == nil {
			t.Errorf("Deserialize(%q) should fail", in)
		}
	}
	if _, err := Deserialize(bytes.Repeat([]byte{tagList, 0, 0, 0, 1}, 2000)); err == nil {
		t.Error("absurd nesting should fail")
	}
}
