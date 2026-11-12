package protowire_test

import (
	"encoding/hex"
	"errors"
	"strings"
	"testing"

	"example.com/protowire"
)

const testSchema = `
message Inner { sint32 v = 1; }
message Outer {
  int32 a = 1;
  string b = 2;
  repeated int32 c = 3;
  Inner d = 4;
}
message M {
  uint64 u = 1; sint64 s = 2; fixed32 f = 3; bytes y = 4;
  repeated bool bs = 5; bool k = 6; sfixed32 sf = 7; fixed64 f64 = 8;
  repeated fixed32 rf = 9; repeated string rs = 10; repeated Inner ri = 11;
  int64 i64 = 12; sint32 s32 = 13; sfixed64 sf64 = 14; uint32 u32 = 15;
}
message P { repeated int32 r = 1; P p = 2; string s = 3; }
`

func mustSchema(t testing.TB) *protowire.Schema {
	t.Helper()
	s, err := protowire.ParseSchema(testSchema)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func mustHex(t testing.TB, h string) []byte {
	t.Helper()
	b, err := hex.DecodeString(h)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestDecode(t *testing.T) {
	s := mustSchema(t)
	tests := []struct {
		name, msg, hex, want string
	}{
		{"empty", "Outer", "", "{}"},
		{"simple", "Outer", "08011201781a02010222020809", `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`},
		{"unknown varint skipped", "Outer", "3800", "{}"},
		{"present empty submessage", "Outer", "2200", "{d: {}}"},
		{"int32 negative", "Outer", "08ffffffffffffffffff01", "{a: -1}"},
		{"int32 truncates high bits", "Outer", "08ffffffff0f", "{a: -1}"},
		{"nonminimal varint", "Outer", "088100", "{a: 1}"},
		{"varint 10th byte bits discarded", "M", "1080808080808080808002", "{}"},
		{"max uint64", "M", "08ffffffffffffffffff7f", "{u: 18446744073709551615}"},
		{"bool 2 is true", "M", "3002", "{k: true}"},
		{"bool list", "M", "2a03010001", "{bs: [true, false, true]}"},
		{"fixed32 unsigned", "M", "1dffffffff", "{f: 4294967295}"},
		{"sfixed32 signed", "M", "3dffffffff", "{sf: -1}"},
		{"fixed64", "M", "41ffffffffffffffff", "{f64: 18446744073709551615}"},
		{"sint64 min", "M", "10ffffffffffffffffff01", "{s: -9223372036854775808}"},
		{"sint32 unzigzag", "M", "6809", "{s32: -5}"},
		{"packed fixed32", "M", "4a080100000002000000", "{rf: [1, 2]}"},
		{"mixed packed/unpacked", "P", "0801" + "0a020203" + "0804", "{r: [1, 2, 3, 4]}"},
		{"empty packed", "P", "0a00", "{}"},
		{"string escapes", "P", "1a0322095c", `{s: "\"\t\\"}`},
		{"string control chars", "P", "1a04007f1f0d", `{s: "\x00\x7f\x1f\r"}`},
		{"string utf8 raw", "P", "1a02c3a9", `{s: "é"}`},
		{"bytes", "M", "2202000f", `{y: x"000f"}`},
		{"wrong wire type skipped", "Outer", "0d00000000", "{}"},
		{"singular numeric wire type 2 skipped", "Outer", "0a0101", "{}"},
		{"group skipped", "P", "1b08011c0805", "{r: [5]}"},
		{"nested group skipped", "P", "1b13141c", "{}"},
		{"submessage merge", "P", "0801080212020803120208041a0322095c", `{r: [1, 2], p: {r: [3, 4]}, s: "\"\t\\"}`},
		{"repeated strings", "M", "520161520262625200", `{rs: ["a", "bb", ""]}`},
		{"repeated messages", "M", "5a0208025a00", `{ri: [{v: 1}, {}]}`},
		{"scalar replaced", "Outer", "08010802", "{a: 2}"},
		{"default omitted", "Outer", "0800", "{}"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			m, err := s.Message(tc.msg).Unmarshal(mustHex(t, tc.hex))
			if err != nil {
				t.Fatalf("Unmarshal: %v", err)
			}
			if got := m.String(); got != tc.want {
				t.Errorf("got  %s\nwant %s", got, tc.want)
			}
		})
	}
}

func TestDecodeErrors(t *testing.T) {
	s := mustSchema(t)
	tests := []struct{ name, msg, hex string }{
		{"truncated varint", "Outer", "08ff"},
		{"varint too long", "Outer", "08ffffffffffffffffffff01"},
		{"unknown varint too long", "Outer", "38ffffffffffffffffffff01"},
		{"tag too long", "Outer", "8080808080 00"},
		{"tag too large", "Outer", "f8ffffff1f"},
		{"field number zero", "Outer", "0000"},
		{"wire type 6", "Outer", "0e"},
		{"wire type 7", "Outer", "0f"},
		{"end group at top level", "Outer", "0c"},
		{"mismatched end group", "P", "1b08011400"},
		{"unclosed group", "P", "1b0801"},
		{"group wire type 6 inside", "P", "1b0e1c"},
		{"truncated fixed32 unknown", "M", "3d000000"},
		{"truncated fixed64", "M", "41000000"},
		{"length exceeds remaining", "Outer", "1205 78"},
		{"length prefix 6 bytes", "Outer", "1280808080808000"},
		{"invalid utf8", "Outer", "1201ff"},
		{"surrogate utf8", "Outer", "1203eda080"},
		{"overlong utf8", "Outer", "1202c080"},
		{"packed fixed32 bad length", "M", "4a0301000000"},
		{"packed varint truncated", "P", "0a0180"},
		{"submessage error", "Outer", "22020880"},
		{"truncated multibyte utf8", "P", "1a01c3"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := s.Message(tc.msg).Unmarshal(mustHex(t, strings.ReplaceAll(tc.hex, " ", "")))
			if err == nil {
				t.Fatal("expected error")
			}
			if !errors.Is(err, protowire.ErrDecode) {
				t.Errorf("error %v does not wrap ErrDecode", err)
			}
		})
	}
}

func TestEncode(t *testing.T) {
	s := mustSchema(t)
	tests := []struct {
		name, msg, text, want string
	}{
		{"example", "Outer", `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`, "08011201781a02010222020809"},
		{"defaults vanish", "Outer", `{d: {}, c: [], a: 0}`, "2200"},
		{"empty", "Outer", `{}`, ""},
		{"all defaults", "M", `{u: 0, y: x"", k: false, bs: [], rs: []}`, ""},
		{"reordered", "M", `{k: true, y: x"cafe", s: -128, u: 18446744073709551615}`, "08ffffffffffffffffff0110ff012202cafe3001"},
		{"no spaces", "Outer", `{a:1,c:[1,2]}`, "08011a020102"},
		{"extra spaces", "Outer", `   {  a  :  1  ,  c : [ 1 , 2 ]  }   `, "08011a020102"},
		{"int32 negative is 10 bytes", "Outer", `{a: -1}`, "08ffffffffffffffffff01"},
		{"int32 min", "Outer", `{a: -2147483648}`, "0880808080f8ffffffff01"},
		{"zeros kept in packed", "Outer", `{c: [0, 0]}`, "1a020000"},
		{"300", "Outer", `{a: 300}`, "08ac02"},
		{"sint32 min", "M", `{s32: -2147483648}`, "68ffffffff0f"},
		{"sint64 min", "M", `{s: -9223372036854775808}`, "10ffffffffffffffffff01"},
		{"sfixed32", "M", `{sf: -1}`, "3dffffffff"},
		{"fixed64", "M", `{f64: 1}`, "410100000000000000"},
		{"packed bools", "M", `{bs: [true, false, true]}`, "2a03010001"},
		{"packed fixed32", "M", `{rf: [1, 2]}`, "4a080100000002000000"},
		{"string escapes", "P", `{s: "\"\t\\\n\r\x41\x7F"}`, "1a07" + "22095c0a0d417f"},
		{"string utf8 via hex escapes", "P", `{s: "\xc3\xa9"}`, "1a02c3a9"},
		{"raw utf8 and DEL", "P", "{s: \"\u00e9\x7f\"}", "1a03c3a97f"},
		{"repeated strings", "M", `{rs: ["a", "", "bb"]}`, "520161520052026262"},
		{"repeated messages", "M", `{ri: [{v: 1}, {}]}`, "5a0208025a00"},
		{"recursive", "P", `{p: {p: {r: [1]}}}`, "1205" + "1203" + "0a0101"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			m, err := s.Message(tc.msg).ParseText([]byte(tc.text))
			if err != nil {
				t.Fatalf("ParseText: %v", err)
			}
			if got := hex.EncodeToString(m.Marshal()); got != tc.want {
				t.Errorf("got  %s\nwant %s", got, tc.want)
			}
		})
	}
}

func TestParseTextErrors(t *testing.T) {
	s := mustSchema(t)
	tests := []struct{ name, msg, text string }{
		{"empty text", "Outer", ``},
		{"only spaces", "Outer", `   `},
		{"unknown field", "Outer", `{zzz: 1}`},
		{"duplicate field", "Outer", `{a: 1, a: 2}`},
		{"duplicate repeated field", "Outer", `{c: [1], c: [2]}`},
		{"list for singular", "Outer", `{a: [1]}`},
		{"scalar for repeated", "Outer", `{c: 1}`},
		{"string for int", "Outer", `{a: "1"}`},
		{"message for scalar", "Outer", `{a: {}}`},
		{"int for string", "Outer", `{b: 1}`},
		{"int for bool", "M", `{k: 1}`},
		{"string for bool", "M", `{k: "true"}`},
		{"capital True", "M", `{k: True}`},
		{"int32 too big", "Outer", `{a: 2147483648}`},
		{"int32 too small", "Outer", `{a: -2147483649}`},
		{"uint32 too big", "M", `{u32: 4294967296}`},
		{"uint64 too big", "M", `{u: 18446744073709551616}`},
		{"int64 too big", "M", `{i64: 9223372036854775808}`},
		{"negative unsigned", "M", `{u: -1}`},
		{"negative zero", "Outer", `{a: -0}`},
		{"leading zeros", "Outer", `{a: 007}`},
		{"plus sign", "Outer", `{a: +5}`},
		{"float", "Outer", `{a: 1.0}`},
		{"space in number", "Outer", `{a: - 1}`},
		{"space in bytes prefix", "M", `{y: x "00"}`},
		{"space in bool", "M", `{k: tr ue}`},
		{"missing comma", "Outer", `{a: 1 b: "x"}`},
		{"trailing comma", "Outer", `{a: 1,}`},
		{"list trailing comma", "Outer", `{c: [1,]}`},
		{"list missing comma", "Outer", `{c: [1 2]}`},
		{"missing colon", "Outer", `{a 1}`},
		{"unclosed brace", "Outer", `{a: 1`},
		{"unclosed list", "Outer", `{c: [1}`},
		{"trailing text", "Outer", `{} x`},
		{"tab separator", "Outer", "{a:\t1}"},
		{"unterminated string", "Outer", `{b: "x}`},
		{"bad escape", "Outer", `{b: "\q"}`},
		{"short hex escape", "Outer", `{b: "\x4"}`},
		{"raw control char", "Outer", "{b: \"\x01\"}"},
		{"raw newline", "Outer", "{b: \"\n\"}"},
		{"invalid utf8 after unescape", "Outer", `{b: "\xff"}`},
		{"surrogate via escapes", "Outer", `{b: "\xed\xa0\x80"}`},
		{"uppercase bytes hex", "M", `{y: x"CAFE"}`},
		{"odd bytes hex", "M", `{y: x"caf"}`},
		{"non-hex bytes", "M", `{y: x"zz"}`},
		{"bytes without x", "M", `{y: "00"}`},
		{"list of lists", "Outer", `{c: [[1]]}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := s.Message(tc.msg).ParseText([]byte(tc.text))
			if err == nil {
				t.Fatal("expected error")
			}
			if !errors.Is(err, protowire.ErrText) {
				t.Errorf("error %v does not wrap ErrText", err)
			}
		})
	}
}

func TestRoundTrip(t *testing.T) {
	s := mustSchema(t)
	text := `{u: 1, s: -2, f: 3, y: x"00ff", bs: [true, false], k: true, sf: -4, f64: 5, rf: [0, 7], ` +
		`rs: ["a\n", ""], ri: [{v: -1}, {}], i64: -9223372036854775808, s32: -7, sf64: -8, u32: 9}`
	d := s.Message("M")
	m, err := d.ParseText([]byte(text))
	if err != nil {
		t.Fatal(err)
	}
	wire := m.Marshal()
	m2, err := d.Unmarshal(wire)
	if err != nil {
		t.Fatal(err)
	}
	want := `{u: 1, s: -2, f: 3, y: x"00ff", bs: [true, false], k: true, sf: -4, f64: 5, rf: [0, 7], ` +
		`rs: ["a\n", ""], ri: [{v: -1}, {}], i64: -9223372036854775808, s32: -7, sf64: -8, u32: 9}`
	if got := m2.String(); got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
	if again := m2.Marshal(); string(again) != string(wire) {
		t.Errorf("re-marshal differs: %x vs %x", again, wire)
	}
}

func TestGet(t *testing.T) {
	s := mustSchema(t)
	m, err := s.Message("Outer").ParseText([]byte(`{a: -3, b: "hi", c: [1, 2], d: {v: 4}}`))
	if err != nil {
		t.Fatal(err)
	}
	if v, ok := m.Get("a"); !ok || v != int64(-3) {
		t.Errorf("a = %v, %v", v, ok)
	}
	if v, _ := m.Get("b"); v != "hi" {
		t.Errorf("b = %v", v)
	}
	if v, _ := m.Get("c"); len(v.([]any)) != 2 || v.([]any)[1] != int64(2) {
		t.Errorf("c = %v", v)
	}
	d, _ := m.Get("d")
	if v, _ := d.(*protowire.Message).Get("v"); v != int64(4) {
		t.Errorf("d.v = %v", v)
	}
	if _, ok := m.Get("nope"); ok {
		t.Error("unknown field reported present")
	}
}

func TestSchema(t *testing.T) {
	s, err := protowire.ParseSchema("message A{int32 x=2;repeated B y = 1;}\nmessage B {A a = 3; string s=4;}")
	if err != nil {
		t.Fatal(err)
	}
	a := s.Message("A")
	if a == nil || len(a.Fields) != 2 || a.Fields[0].Name != "y" || a.Fields[1].Name != "x" {
		t.Fatalf("fields not sorted by number: %+v", a)
	}
	if f := a.FieldByName("y"); !f.Repeated || f.Message != s.Message("B") {
		t.Errorf("bad field y: %+v", f)
	}
	if s.Message("B").FieldByNumber(3).Message != a {
		t.Error("recursive reference not resolved")
	}
	for _, bad := range []string{
		"message A { int32 x = 1 }",
		"message A { foo x = 1; }",
		"message A { int32 x = 1; int32 y = 1; }",
		"message A { int32 x = 0; }",
		"message A { int32 x = 19000; }",
		"message A { } message A { }",
		"message A {",
	} {
		if _, err := protowire.ParseSchema(bad); !errors.Is(err, protowire.ErrSchema) {
			t.Errorf("ParseSchema(%q) = %v, want ErrSchema", bad, err)
		}
	}
}

func TestDeepNesting(t *testing.T) {
	s := mustSchema(t)
	const depth = 64
	text := strings.Repeat("{p: ", depth) + "{}" + strings.Repeat("}", depth)
	d := s.Message("P")
	m, err := d.ParseText([]byte(text))
	if err != nil {
		t.Fatal(err)
	}
	m2, err := d.Unmarshal(m.Marshal())
	if err != nil {
		t.Fatal(err)
	}
	if m2.String() != text {
		t.Errorf("deep round trip mismatch: %s", m2)
	}
}

// TestLargeRepeated checks a 100,000-element packed list round-trips.
func TestLargeRepeated(t *testing.T) {
	s := mustSchema(t)
	var sb strings.Builder
	sb.WriteString("{c: [")
	for i := 0; i < 100000; i++ {
		if i > 0 {
			sb.WriteString(", ")
		}
		sb.WriteString("-1")
	}
	sb.WriteString("]}")
	d := s.Message("Outer")
	m, err := d.ParseText([]byte(sb.String()))
	if err != nil {
		t.Fatal(err)
	}
	wire := m.Marshal()
	m2, err := d.Unmarshal(wire)
	if err != nil {
		t.Fatal(err)
	}
	if m2.String() != sb.String() {
		t.Error("large list round trip mismatch")
	}
}

func FuzzUnmarshal(f *testing.F) {
	s, err := protowire.ParseSchema(testSchema)
	if err != nil {
		f.Fatal(err)
	}
	for _, seed := range []string{"08011201781a02010222020809", "1b08011c0805", "", "0a0180"} {
		b, _ := hex.DecodeString(seed)
		f.Add(b)
	}
	d := s.Message("P")
	f.Fuzz(func(t *testing.T, data []byte) {
		m, err := d.Unmarshal(data)
		if err != nil {
			return
		}
		// Whatever decodes must re-encode to something that decodes to the
		// same text.
		m2, err := d.Unmarshal(m.Marshal())
		if err != nil {
			t.Fatalf("re-decode failed: %v", err)
		}
		if m.String() != m2.String() {
			t.Fatalf("round trip changed value: %s vs %s", m, m2)
		}
	})
}
