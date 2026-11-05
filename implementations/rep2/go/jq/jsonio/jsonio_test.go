package jsonio_test

import (
	"fmt"
	"strings"
	"testing"

	"example.com/jq/jsonio"
	"example.com/jq/value"
)

func TestRoundTrip(t *testing.T) {
	docs := []string{
		`null`, `true`, `false`, `0`, `-12`, `3.25`, `1000000000000`, `0.125`, `3086419725308.5`,
		`""`, `"a b"`, `[]`, `{}`, `[1,[2,[3]]]`, `{"b":1,"a":{"z":[],"y":{}}}`,
		`"é😀"`, `"\"\\\b\f\n\r\t\u0001\u007f"`,
	}
	for _, d := range docs {
		v, err := jsonio.ParseString(d)
		if err != nil {
			t.Errorf("parse %s: %v", d, err)
			continue
		}
		if got := jsonio.Marshal(v); got != d {
			t.Errorf("round trip of %s gave %s", d, got)
		}
	}
}

func TestWhitespaceAndEscapes(t *testing.T) {
	v, err := jsonio.ParseString(" \t\r\n{ \"a\" : [ 1 , 2 ] , \"k\\u00e9\\/\" : \"\\ud83d\\ude00\\uD83D\\uDE00\" }\n ")
	if err != nil {
		t.Fatal(err)
	}
	if got := jsonio.Marshal(v); got != `{"a":[1,2],"ké/":"😀😀"}` {
		t.Errorf("got %s", got)
	}
}

func TestNumbers(t *testing.T) {
	cases := map[string]string{
		"1e2": "100", "1.5e1": "15", "-0.5": "-0.5", "9007199254740991": "9007199254740991",
		"0.001": "0.001", "2.50": "2.5", "1E-2": "0.01",
	}
	for in, want := range cases {
		v, err := jsonio.ParseString(in)
		if err != nil {
			t.Errorf("%s: %v", in, err)
			continue
		}
		if got := jsonio.Marshal(v); got != want {
			t.Errorf("%s printed as %s, want %s", in, got, want)
		}
	}
}

func TestObjectOrderAndDuplicates(t *testing.T) {
	v, err := jsonio.ParseString(`{"z":1,"a":2,"z":3}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := jsonio.Marshal(v); got != `{"z":3,"a":2}` {
		t.Errorf("got %s", got)
	}
}

func TestLargeObject(t *testing.T) {
	var sb strings.Builder
	sb.WriteString("{")
	for i := 0; i < 50; i++ {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(fmt.Sprintf(`"k%d":%d`, i, i%10))
	}
	sb.WriteString("}")
	v, err := jsonio.ParseString(sb.String())
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := v.Obj().Get("k27"); got.Float() != 7 {
		t.Errorf("k27 = %v", got.Float())
	}
	if jsonio.Marshal(v) != sb.String() {
		t.Error("large object did not round trip")
	}
}

func TestSyntaxErrors(t *testing.T) {
	bad := []string{``, `[`, `[1,]`, `{"a"}`, `{"a":1,}`, `01`, `1.`, `-`, `"abc`, `"\x"`, `"\u12"`, `tru`, `[1] 2`, "\"a\nb\"", `nul`, `{1:2}`}
	for _, d := range bad {
		if _, err := jsonio.ParseString(d); err == nil {
			t.Errorf("%q should not parse", d)
		}
	}
}

func TestEncodeNumbers(t *testing.T) {
	a, b := 0.1, 0.2
	cases := map[float64]string{
		0: "0", 3: "3", -12: "-12", 1.5: "1.5", 0.125: "0.125", 1e15: "1000000000000000",
		9007199254740991: "9007199254740991", a + b: "0.30000000000000004", 1.0 / 3: "0.3333333333333333",
	}
	for f, want := range cases {
		if got := string(jsonio.AppendNumber(nil, f)); got != want {
			t.Errorf("%v printed as %s, want %s", f, got, want)
		}
	}
}

func TestEncodeAppends(t *testing.T) {
	buf := []byte("x")
	buf = jsonio.Append(buf, value.Array([]value.Value{value.True, value.Null}))
	if string(buf) != "x[true,null]" {
		t.Errorf("got %s", buf)
	}
}
