package schema

import (
	"fmt"
	"strings"
	"testing"

	"protowire/wire"
)

func TestParseBasics(t *testing.T) {
	src := `
message Outer {
  repeated Inner items = 5;
  int32 a = 1;
  Outer self = 3;
}
message Inner{sint64 v=2;repeated bool flags=1;}
`
	s, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Messages) != 2 {
		t.Fatalf("messages: %d", len(s.Messages))
	}
	outer := s.Lookup("Outer")
	if outer == nil || s.Lookup("Nope") != nil {
		t.Fatal("Lookup")
	}
	// Fields are sorted by number.
	var nums []uint32
	for _, f := range outer.Fields {
		nums = append(nums, f.Number)
	}
	if len(nums) != 3 || nums[0] != 1 || nums[1] != 3 || nums[2] != 5 {
		t.Errorf("order: %v", nums)
	}
	if i := outer.FieldByNumber(3); i != 1 || outer.Fields[i].Name != "self" || outer.Fields[i].Kind != Message {
		t.Errorf("FieldByNumber(3) = %d", i)
	}
	if outer.FieldByNumber(2) != -1 || outer.FieldByNumber(99) != -1 || outer.FieldByNumber(0) != -1 {
		t.Error("missing numbers should give -1")
	}
	if i := outer.FieldByName([]byte("items")); i != 2 {
		t.Errorf("FieldByName(items) = %d", i)
	}
	if outer.FieldByName([]byte("zzz")) != -1 {
		t.Error("FieldByName(zzz)")
	}
	items := outer.Fields[2]
	if !items.Repeated || s.Messages[items.Message].Name != "Inner" {
		t.Errorf("items: %+v", items)
	}
	if outer.Fields[1].Message != 0 {
		t.Error("recursive type should resolve to its own index")
	}
	inner := s.LookupBytes([]byte("Inner"))
	flags := inner.Fields[0]
	if flags.Kind != Bool || !flags.Repeated || flags.WireType != wire.Varint {
		t.Errorf("flags: %+v", flags)
	}
	// Repeated numeric fields are tagged as length-delimited (packed).
	if string(flags.Tag) != "\x0a" {
		t.Errorf("packed tag: %x", flags.Tag)
	}
	if string(inner.Fields[1].Tag) != "\x10" { // field 2, varint
		t.Errorf("sint64 tag: %x", inner.Fields[1].Tag)
	}
}

func TestKindProperties(t *testing.T) {
	for k, want := range map[Kind]int{Int32: 0, Bool: 0, Fixed32: 5, Sfixed32: 5, Fixed64: 1, Sfixed64: 1, String: 2, BytesKind: 2, Message: 2} {
		if k.WireType() != want {
			t.Errorf("%v wire type %d, want %d", k, k.WireType(), want)
		}
	}
	if !Sint32.Signed() || Uint32.Signed() || Fixed32.Signed() || !Sfixed32.Signed() {
		t.Error("Signed")
	}
	if !Fixed64.IsNumeric() || String.IsNumeric() || Message.IsNumeric() {
		t.Error("IsNumeric")
	}
	if Sfixed64.String() != "sfixed64" {
		t.Error("String")
	}
}

func TestParseErrors(t *testing.T) {
	bad := map[string]string{
		"unknown type":   "message A { Foo x = 1; }",
		"dup message":    "message A {} message A {}",
		"dup number":     "message A { int32 x = 1; int32 y = 1; }",
		"dup name":       "message A { int32 x = 1; int32 x = 2; }",
		"zero number":    "message A { int32 x = 0; }",
		"huge number":    "message A { int32 x = 536870912; }",
		"missing semi":   "message A { int32 x = 1 }",
		"missing brace":  "message A { int32 x = 1;",
		"bad char":       "message A { int32 x = 1; } #",
		"not message":    "enum A {}",
		"reserved field": "message A { int32 int32 = 1; }",
	}
	for name, src := range bad {
		if _, err := Parse([]byte(src)); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
	var sb strings.Builder
	sb.WriteString("message A {")
	for i := 1; i <= 65; i++ {
		fmt.Fprintf(&sb, " int32 f%d = %d;", i, i)
	}
	sb.WriteString("}")
	if _, err := Parse([]byte(sb.String())); err == nil {
		t.Error("expected error for more than 64 fields")
	}
}

func TestParseEmpty(t *testing.T) {
	s, err := Parse([]byte("  \n"))
	if err != nil || len(s.Messages) != 0 {
		t.Errorf("empty schema: %v %v", s, err)
	}
}
