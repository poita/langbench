package jq

import "testing"

func TestRoundTrip(t *testing.T) {
	for _, s := range []string{
		`null`, `true`, `false`, `0`, `-12`, `1000000000000`, `1.5`, `0.125`, `3086419725308.5`,
		`""`, `"a\"b\\c\n\t\u0001é😀"`, `[]`, `{}`, `[1,[2,[3]]]`,
		`{"z":1,"a":{"k":[null]},"m":"x"}`,
	} {
		v, err := ParseJSONString(s)
		if err != nil {
			t.Errorf("parse %s: %v", s, err)
			continue
		}
		if got := string(Marshal(v)); got != s {
			t.Errorf("round trip %s -> %s", s, got)
		}
	}
}

func TestDecodeDetails(t *testing.T) {
	v, err := ParseJSONString(" \t\r\n{ \"a\" : [ 1e2 , \"\\ud83d\\ude00\\u00E9\\/\" ] }\n")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(Marshal(v)), `{"a":[100,"😀é/"]}`; got != want {
		t.Errorf("got %s want %s", got, want)
	}
}

func TestDecodeErrors(t *testing.T) {
	for _, s := range []string{``, `[1,]`, `{"a"}`, `01`, `1.`, `"abc`, `[1] x`, `tru`, `"\x"`, "\"a\nb\"", `-`} {
		if _, err := ParseJSONString(s); err == nil {
			t.Errorf("ParseJSON(%q) succeeded, want error", s)
		}
	}
}

func TestEscapes(t *testing.T) {
	got := string(Marshal("\x00\x08\x0c\n\r\t\x1f\x7f/<>&\"\\é"))
	want := `"\u0000\b\f\n\r\t\u001f\u007f/<>&\"\\é"`
	if got != want {
		t.Errorf("got %s want %s", got, want)
	}
}

func TestNumberFormatting(t *testing.T) {
	tenth, fifth := 0.1, 0.2
	for in, want := range map[float64]string{
		0: "0", 3: "3", -12: "-12", 1.5: "1.5", 0.001: "0.001", 123456.789: "123456.789",
		9007199254740991: "9007199254740991", tenth + fifth: "0.30000000000000004",
	} {
		if got := string(Marshal(in)); got != want {
			t.Errorf("Marshal(%v) = %s, want %s", in, got, want)
		}
	}
}

func TestCompare(t *testing.T) {
	ordered := []string{`null`, `false`, `true`, `-1`, `0`, `2.5`, `""`, `"a"`, `"ab"`, `"b"`, `"z"`, `"é"`,
		`[]`, `[0]`, `[0,1]`, `[1]`, `{}`, `{"a":1}`, `{"a":2}`, `{"b":0}`}
	for i, a := range ordered {
		for j, b := range ordered {
			va, _ := ParseJSONString(a)
			vb, _ := ParseJSONString(b)
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := Compare(va, vb); got != want {
				t.Errorf("Compare(%s, %s) = %d, want %d", a, b, got, want)
			}
		}
	}
}

func TestObjectBasics(t *testing.T) {
	o := NewObject(0)
	for i := 0; i < 100; i++ {
		o.Set(string(Marshal(float64(i))), i)
	}
	o.Set("5", "new")
	if o.Len() != 100 {
		t.Fatalf("len %d", o.Len())
	}
	if v, ok := o.Get("5"); !ok || v != "new" {
		t.Errorf("Get(5) = %v %v", v, ok)
	}
	if k, _ := o.At(5); k != "5" {
		t.Errorf("position of replaced key changed: %s", k)
	}
	if ks := o.SortedKeys(); ks[0] != "0" || ks[1] != "1" || ks[2] != "10" {
		t.Errorf("sorted keys %v", ks[:3])
	}
}
