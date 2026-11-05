package codec

import (
	"encoding/hex"
	"strings"
	"testing"

	"protowire/schema"
)

func mustSchema(t testing.TB, src string) *Codec {
	t.Helper()
	s, err := schema.Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	return New(s)
}

func unhex(t testing.TB, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

type dcase struct{ msg, hex, want string } // want "!" means error

func runDecode(t *testing.T, c *Codec, cases []dcase) {
	t.Helper()
	for _, tc := range cases {
		got, err := c.Decode(tc.msg, unhex(t, tc.hex))
		if tc.want == "!" {
			if err == nil {
				t.Errorf("decode %s %s = %q, want error", tc.msg, tc.hex, got)
			}
			continue
		}
		if err != nil || got != tc.want {
			t.Errorf("decode %s %s = %q, %v; want %q", tc.msg, tc.hex, got, err, tc.want)
		}
	}
}

const specSchema1 = `
message Inner { sint32 v = 1; }
message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }`

func TestSpecExample1(t *testing.T) {
	c := mustSchema(t, specSchema1)
	runDecode(t, c, []dcase{
		{"Outer", "08011201781a02010222020809", `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`},
		{"Outer", "2200", `{d: {}}`},
		{"Outer", "3800", `{}`},
		{"Outer", "", `{}`},
		{"Outer", "08ff", "!"},
	})
	enc, err := c.Encode("Outer", `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`)
	if err != nil || hex.EncodeToString(enc) != "08011201781a02010222020809" {
		t.Errorf("encode = %x, %v", enc, err)
	}
	enc, err = c.Encode("Outer", `{d: {}, c: [], a: 0}`)
	if err != nil || hex.EncodeToString(enc) != "2200" {
		t.Errorf("encode = %x, %v", enc, err)
	}
	enc, err = c.Encode("Outer", `{}`)
	if err != nil || len(enc) != 0 {
		t.Errorf("empty encode = %x, %v", enc, err)
	}
}

func TestScalars(t *testing.T) {
	c := mustSchema(t, `message M { uint64 u = 1; sint64 s = 2; fixed32 f = 3; bytes y = 4; repeated bool bs = 5; bool k = 6; }`)
	runDecode(t, c, []dcase{
		{"M", "08ffffffffffffffffff0110ff011dffffffff2202000f2a03010001", `{u: 18446744073709551615, s: -128, f: 4294967295, y: x"000f", bs: [true, false, true]}`},
		{"M", "3002", `{k: true}`},
		{"M", "3d000000", "!"},
	})
	enc, err := c.Encode("M", `{k: true, y: x"cafe", s: -128, u: 18446744073709551615}`)
	if err != nil || hex.EncodeToString(enc) != "08ffffffffffffffffff0110ff012202cafe3001" {
		t.Errorf("encode = %x, %v", enc, err)
	}
	if _, err := c.Encode("M", `{u: -1}`); err == nil {
		t.Error("u: -1 accepted")
	}
}

func TestMergeUnpackedAndGroups(t *testing.T) {
	c := mustSchema(t, `message P { repeated int32 r = 1; P p = 2; string s = 3; }`)
	runDecode(t, c, []dcase{
		{"P", "0801080212020803120208041a0322095c", `{r: [1, 2], p: {r: [3, 4]}, s: "\"\t\\"}`},
		{"P", "1b08011c0805", `{r: [5]}`},
		{"P", "1b08011400", "!"},
		{"P", "1b0801", "!"},              // group never closed
		{"P", "1c", "!"},                  // end group outside a group
		{"P", "1b231c", "!"},              // nested group: inner start never closed
		{"P", "1b2b2c1c0801", `{r: [1]}`}, // nested groups skipped
		{"P", "1b0001", "!"},              // field number 0 inside group... tag 00 invalid
		{"P", "0b0c", "{}"},               // empty group closed by 0c
		{"P", "0e", "!"},                  // wire type 6
		{"P", "0f", "!"},                  // wire type 7
		{"P", "00", "!"},                  // field number 0
		{"P", "80808080800100", "!"},      // 6-byte tag
	})
}

func TestPacked(t *testing.T) {
	c := mustSchema(t, `message M { repeated fixed32 f = 1; repeated fixed64 g = 2; repeated sint32 s = 3; repeated string t = 4; int32 one = 5; }`)
	runDecode(t, c, []dcase{
		{"M", "0a0801000000ffffffff", `{f: [1, 4294967295]}`},
		{"M", "0a05010000000a", "!"},
		{"M", "0a00", `{}`},
		{"M", "0d01000000" + "0a0402000000", `{f: [1, 2]}`}, // mixed unpacked and packed
		{"M", "12080100000000000000", `{g: [1]}`},
		{"M", "1207" + "00000000000000", "!"},
		{"M", "1a03010380", "!"}, // packed varint cut in the middle
		{"M", "1a03010203", `{s: [-1, 1, -2]}`},
		{"M", "2200", `{t: [""]}`},
		{"M", "220161220162", `{t: ["a", "b"]}`},
		{"M", "2a00", `{}`}, // packed form on a singular int32 is skipped
		{"M", "2a0301", "!"},
	})
}

func TestStringValidation(t *testing.T) {
	c := mustSchema(t, `message M { string s = 1; bytes b = 2; }`)
	runDecode(t, c, []dcase{
		{"M", "0a03e282ac", `{s: "€"}`},
		{"M", "0a02c0af", "!"},     // overlong
		{"M", "0a03eda080", "!"},   // surrogate
		{"M", "0a04f4908080", "!"}, // > U+10FFFF
		{"M", "0a02e282", "!"},     // truncated
		{"M", "1203c0af00", `{b: x"c0af00"}`},
		{"M", "0a0700017f1f0a0d09", `{s: "\x00\x01\x7f\x1f\n\r\t"}`},
	})
}

func TestUnknownFieldsAreValidatedWhileSkipped(t *testing.T) {
	c := mustSchema(t, `message M { int32 a = 1; }`)
	runDecode(t, c, []dcase{
		{"M", "3801" + "0807", `{a: 7}`},
		{"M", "410100000000000000" + "0807", `{a: 7}`},
		{"M", "41060000000000", "!"},
		{"M", "3a05aa", "!"},
		{"M", "3a0aaa", "!"},
		{"M", "3a808080808001", "!"}, // 6-byte length prefix
		{"M", "3880808080808080808080" + "00", "!"},
		{"M", "3880808080808080808002", `{}`},
		{"M", "0a00", `{}`}, // known field, wrong wire type: skipped
		{"M", "0d01000000", `{}`},
		{"M", "09" + "0100000000000000", `{}`},
	})
}

func TestEncodeText(t *testing.T) {
	c := mustSchema(t, `
message Item { int32 id = 1; }
message M {
  int32 i = 1; int64 l = 2; uint32 u = 3; sint32 z = 4; sfixed32 sf = 5; sfixed64 sl = 6;
  string s = 7; bytes y = 8; bool b = 9; Item it = 10; repeated Item items = 11;
  repeated string names = 12; repeated sint64 zs = 13;
}`)
	ok := map[string]string{
		`{}`:                "",
		`  {  }  `:          "",
		`{i:5}`:             "0805",
		`{ i : 5 , l : 6 }`: "08051006",
		`{i: -1}`:           "08ffffffffffffffffff01",
		`{i: 0, s: "", y: x"", b: false, names: []}`: "",
		`{s: "\xc3\xa9"}`:                     "3a02c3a9",
		`{s: "é"}`:                            "3a02c3a9",
		`{s: "a\x41\x4A\"\\\n\r\t"}`:          "3a0861414a225c0a0d09",
		"{s: \"\x7f\"}":                       "3a017f",
		`{y: x"00ff"}`:                        "420200ff",
		`{b: true}`:                           "4801",
		`{it: {}}`:                            "5200",
		`{it: {id: 3}, items: [{}, {id: 1}]}`: "52020803" + "5a00" + "5a020801",
		`{names: ["a", ""]}`:                  "62016162" + "00",
		`{zs: [0, -1, 1]}`:                    "6a03000102",
		`{z: -2147483648}`:                    "20ffffffff0f",
		`{sf: -1}`:                            "2dffffffff",
		`{sl: -2}`:                            "31feffffffffffffff",
		`{u: 4294967295}`:                     "18ffffffff0f",
		`{l: -9223372036854775808}`:           "1080808080808080808001",
	}
	for text, want := range ok {
		got, err := c.Encode("M", text)
		if err != nil || hex.EncodeToString(got) != want {
			t.Errorf("encode %q = %x, %v; want %s", text, got, err, want)
		}
	}
	bad := []string{
		``, ` `, `{`, `}`, `{} x`, `{}{}`, `{a: 1}`, `{i: 1, i: 2}`, `{i: 0, i: 0}`, `{names: [], names: []}`,
		`{i: 1,}`, `{,}`, `{i: 1 l: 2}`, `{i 1}`, `{i: }`, `{i:: 1}`,
		`{i: 007}`, `{i: -0}`, `{i: +5}`, `{i: 1.0}`, `{i: - 1}`, `{i: 2147483648}`, `{i: -2147483649}`,
		`{l: 9223372036854775808}`, `{l: 99999999999999999999999}`, `{u: -1}`, `{u: 4294967296}`,
		`{i: "1"}`, `{i: true}`, `{i: {}}`, `{i: [1]}`, `{i: x"00"}`,
		`{b: 1}`, `{b: 0}`, `{b: True}`, `{b: tr ue}`, `{b: "true"}`, `{b: truex}`,
		`{s: 1}`, `{s: x"00"}`, `{s: "abc}`, `{s: "a\qb"}`, `{s: "a\x4"}`, `{s: "a\xzz"}`, `{s: "\xff"}`, `{s: "\xc3"}`,
		"{s: \"a\tb\"}", "{s: \"a\nb\"}", "{\ti: 1}", `{y: x "00"}`, `{y: x"0"}`, `{y: x"0G"}`, `{y: x"AB"}`, `{y: "00"}`, `{y: x"00}`,
		`{it: 1}`, `{it: [{}]}`, `{items: {}}`, `{items: [1]}`, `{items: [{},]}`, `{items: [,{}]}`, `{items: [{} {}]}`,
		`{names: "a"}`, `{names: [1]}`, `{names: [["a"]]}`, `{zs: 1}`, `{zs: [1,]}`, `{zs: [`, `{zs: [1`,
		`{it: {id: 1}`, `{it: {nope: 1}}`,
	}
	for _, text := range bad {
		if got, err := c.Encode("M", text); err == nil {
			t.Errorf("encode %q = %x, want error", text, got)
		}
	}
}

func TestNestedMerge(t *testing.T) {
	c := mustSchema(t, `message N { int32 a = 1; repeated int32 r = 2; N n = 3; }`)
	// n:{a:1, r:[1], n:{a:5}} then n:{a:2, r:[2], n:{r:[7]}} merge recursively.
	a := "0801" + "1001" + "1a0208" + "05"
	b := "0802" + "1002" + "1a021007"
	msg := "1a" + lenHex(a) + a + "1a" + lenHex(b) + b
	runDecode(t, c, []dcase{{"N", msg, `{n: {a: 2, r: [1, 2], n: {a: 5, r: [7]}}}`}})
}

func lenHex(h string) string {
	n := len(h) / 2
	return string("0123456789abcdef"[n>>4]) + string("0123456789abcdef"[n&15])
}

func TestRoundTrip(t *testing.T) {
	c := mustSchema(t, `
message In { repeated sfixed64 q = 1; string s = 2; }
message M { int32 a = 1; repeated In ins = 2; repeated uint32 u = 3; bytes y = 4; }`)
	texts := []string{
		`{}`,
		`{a: -7, ins: [{q: [1, -1], s: "héllo \"q\"\n"}, {}], u: [0, 4294967295], y: x"00ff"}`,
		`{ins: [{}, {}, {}]}`,
	}
	for _, text := range texts {
		enc, err := c.Encode("M", text)
		if err != nil {
			t.Fatalf("encode %s: %v", text, err)
		}
		dec, err := c.Decode("M", enc)
		if err != nil || dec != text {
			t.Errorf("round trip %s -> %x -> %s (%v)", text, enc, dec, err)
		}
	}
}

func TestUnknownMessage(t *testing.T) {
	c := mustSchema(t, `message M {}`)
	if _, err := c.Decode("X", nil); err != ErrUnknownMessage {
		t.Errorf("Decode: %v", err)
	}
	if _, err := c.Encode("X", "{}"); err != ErrUnknownMessage {
		t.Errorf("Encode: %v", err)
	}
}

func TestDepthLimit(t *testing.T) {
	c := mustSchema(t, `message N { N n = 1; }`)
	text := strings.Repeat("{n: ", 60) + "{}" + strings.Repeat("}", 60)
	enc, err := c.Encode("N", text)
	if err != nil {
		t.Fatal(err)
	}
	if dec, err := c.Decode("N", enc); err != nil || dec != text {
		t.Errorf("depth 60 round trip failed: %v", err)
	}
	deep := strings.Repeat("{n: ", 200) + "{}" + strings.Repeat("}", 200)
	if _, err := c.Encode("N", deep); err != ErrDepth {
		t.Errorf("encode too deep: %v", err)
	}
	groups := strings.Repeat("0b", 200) + strings.Repeat("0c", 200)
	if _, err := c.Decode("N", unhex(t, groups)); err == nil {
		t.Error("deep groups accepted")
	}
}

func TestEscapingOnDecode(t *testing.T) {
	c := mustSchema(t, `message M { string s = 1; }`)
	runDecode(t, c, []dcase{
		{"M", "0a09" + "22" + "5c" + "0a0d09" + "1f7f" + "c3a9", `{s: "\"\\\n\r\t\x1f\x7fé"}`},
	})
}

func BenchmarkEncodeDecodeRepeated(b *testing.B) {
	c := mustSchema(b, `message M { repeated int32 xs = 1; }`)
	var sb strings.Builder
	sb.WriteString("{xs: [")
	for i := 0; i < 100000; i++ {
		if i > 0 {
			sb.WriteString(", ")
		}
		sb.WriteString("-12345")
	}
	sb.WriteString("]}")
	text := sb.String()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		enc, err := c.Encode("M", text)
		if err != nil {
			b.Fatal(err)
		}
		if _, err := c.Decode("M", enc); err != nil {
			b.Fatal(err)
		}
	}
}
