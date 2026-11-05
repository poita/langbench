package params

import "testing"

func TestMainAndPlain(t *testing.T) {
	v := Parse(` Text/Plain ; Charset="UTF-8"; x=1; X=2; noeq `)
	if v.Main != "Text/Plain" {
		t.Errorf("Main = %q", v.Main)
	}
	if s, _ := v.Get("charset"); s != "UTF-8" {
		t.Errorf("charset = %q", s)
	}
	if s, _ := v.Get("x"); s != "1" {
		t.Errorf("first occurrence must win, got %q", s)
	}
	if _, ok := v.Get("noeq"); ok {
		t.Error("segment without = must be ignored")
	}
}

func TestFilenameExamples(t *testing.T) {
	cases := []struct{ in, want string }{
		{`a; filename="report.pdf"`, "report.pdf"},
		{`a; filename*=utf-8''a%C3%A9.txt`, "aé.txt"},
		{`a; filename*0="long"; filename*1="name.txt"`, "longname.txt"},
		{`a; filename*0*=utf-8''a%C3%A9; filename*1=".txt"`, "aé.txt"},
		{`a; filename="=?utf-8?Q?a=C3=A9.txt?="`, "aé.txt"},
		{`a; filename=two words.bin`, "two words.bin"},
		{`a; filename*=''caf%E9.txt`, "caf�.txt"},
		{`a; filename*0=a; filename*2=c; filename*10=j`, "acj"},
		{`a; filename="a\\"; x=1`, `a\`},
		{`a; filename*07=x; filename*0=a; filename*00=b`, "ax"},
		{`a; filename=plain; filename*=utf-8''ext`, "ext"},
		{`a; filename*=utf-8''ext; filename*0=num`, "num"},
		{`a; filename*1=b; filename*1*=c; filename*0=a`, "ab"},
		{`a; filename*=us-ascii'en'100%25%zz`, "100%%zz"},
		{`a; *0=x`, ""},
	}
	for _, c := range cases {
		v := Parse(c.in)
		got, ok := v.Get("filename")
		if c.in == `a; *0=x` {
			if ok {
				t.Errorf("%q: filename should be absent", c.in)
			}
			if s, _ := v.Get("*0"); s != "x" {
				t.Errorf("*0 = %q", s)
			}
			continue
		}
		if got != c.want {
			t.Errorf("%q: filename = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestQuotedSemicolonAndUnterminated(t *testing.T) {
	v := Parse(`a; b="x;y"; c="open; d=1`)
	if s, _ := v.Get("b"); s != "x;y" {
		t.Errorf("b = %q", s)
	}
	if s, _ := v.Get("c"); s != "open; d=1" {
		t.Errorf("c = %q", s)
	}
	if _, ok := v.Get("d"); ok {
		t.Error("d is inside the unterminated quote")
	}
}

func TestParenthesesAreOrdinary(t *testing.T) {
	v := Parse(`a; b=(x;y)`)
	if s, _ := v.Get("b"); s != "(x" {
		t.Errorf("b = %q", s)
	}
}
