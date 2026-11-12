package tessera

import (
	"strings"
	"testing"
)

func kindOfLine(line string) string {
	_, err := ParseCommand(line)
	if err == nil {
		return "ok"
	}
	return string(KindOf(err))
}

func TestParseErrors(t *testing.T) {
	deep := func(n int) string { return strings.Repeat("[", n) }
	tests := []struct {
		line string
		want string
	}{
		{"", "syntax"},
		{"   \t ", "syntax"},
		{`"put" 1`, "syntax"},
		{"frobnicate", "unknown-command"},
		{`frobnicate "\ud800"`, "unknown-command"},
		{"PUT \"a\" 1", "unknown-command"},
		{`put "a"`, "syntax"},
		{`put "a" 007`, "syntax"},
		{`put "a" -0`, "syntax"},
		{`put "a" +1`, "syntax"},
		{`put "a" -`, "syntax"},
		{`put "a" 0`, "ok"},
		{`put "a" -9223372036854775808`, "ok"},
		{`put "a" 9223372036854775807`, "ok"},
		{`put "a" 9223372036854775808`, "int-range"},
		{`put "a" -9223372036854775809`, "int-range"},
		{`put "a" {x:1,x:2}`, "dup-field"},
		{`put "a" {x:1,x}`, "dup-field"},
		{`put "a" {x:1,x 2}`, "dup-field"},
		{`put "a" {x:1,"x":2}`, "dup-field"},
		{`put "a" [1,]`, "syntax"},
		{`put "a" {a:1,}`, "syntax"},
		{`put "\ud800" 1`, "bad-utf8"},
		{`put "\udc00" 1`, "bad-utf8"},
		{`put "\ud800A" 1`, "bad-utf8"},
		{`put "😀" 1`, "ok"},
		{`put "\u00zz" 1`, "syntax"},
		{`put "\ud800\u00zz" 1`, "syntax"},
		{`put "a\qb" 1`, "syntax"},
		{`put "abc 1`, "syntax"},
		{"put \"a\tb\" 1", "syntax"},
		{`put "" 1`, "bad-key"},
		{`put "` + strings.Repeat("k", 129) + `" 1`, "bad-key"},
		{`put "` + strings.Repeat("k", 128) + `" 1`, "ok"},
		{`put "a" 1 99999999999999999999`, "syntax"},
		{`get "a" "\ud800"`, "syntax"},
		{`put 1 "x"`, "syntax"},
		{`put "a" =`, "syntax"},
		{`put "a" é`, "syntax"},
		{`begin now`, "syntax"},
		{deep(32) + "]" + strings.Repeat("]", 31), "syntax"}, // not a command
		{`put "a" ` + deep(32) + strings.Repeat("]", 32), "ok"},
		{`put "a" ` + deep(32) + `1` + strings.Repeat("]", 32), "depth"},
		{`put "a" ` + deep(32) + `99999999999999999999`, "depth"},
		{`put "a" ` + deep(32) + `"\ud800"`, "depth"},
		{`put "a" ` + deep(32), "depth"},
		{`put "a" ` + deep(32) + `-`, "syntax"},
		{`put "a" ` + deep(30) + `{x:[[1]],x:1}`, "depth"},
		{`put "a" ` + deep(30) + `{x:1,x:[[1]]}`, "dup-field"},
		{`put "a" ` + deep(31) + `{}` + strings.Repeat("]", 31), "ok"},
		{`put "a" ` + deep(31) + `{x:1}` + strings.Repeat("]", 31), "depth"},
		{`scan from "a" from "b"`, "syntax"},
		{`scan limit -1`, "syntax"},
		{`scan limit 2147483648`, "syntax"},
		{`scan limit 99999999999999999999`, "int-range"},
		{`scan limit 2147483647 reverse keys from "" to "\u0000"`, "ok"},
		{`scan bogus`, "syntax"},
		{`scan limit`, "syntax"},
		{`scan from "` + strings.Repeat("k", 300) + `"`, "ok"},
		{`create index a.b.c`, "ok"},
		{`create idx a`, "syntax"},
		{`create index a.`, "syntax"},
		{`create index a.b.c.d.e.f.g.h.i.`, "bad-path"},
		{`create index ` + strings.Repeat("a", 31) + `.`, "bad-path"},
		{`create index ` + strings.Repeat("a", 30), "ok"},
		{`create index aaaaaaaaaa.bbbbbbbbbb.cccccccccc.d`, "bad-path"},
		{`create index a . b`, "ok"},
		{`drop index null`, "ok"},
		{`update "a" x.y`, "syntax"},
		{`unset "a" x.y z`, "syntax"},
		{`find a == 1 limit 5`, "ok"},
		{`find a == 1 limit`, "syntax"},
		{`find a == 1 bogus`, "syntax"},
		{`find a ==`, "syntax"},
		{`find`, "syntax"},
		{`find (a == 1`, "syntax"},
		{`find not (a == 1)`, "ok"},
		{`find not a == 1`, "syntax"},
		{`find exists a.b and missing c or not(d < "x")`, "ok"},
		{`find exists == 1`, "ok"},
		{`find and == 1`, "ok"},
		{`find a == 1 and`, "syntax"},
		{`find a < 1 < 2`, "syntax"},
		{`find a.b.c.d.e.f.g.h.i == 1`, "bad-path"},
	}
	for _, tc := range tests {
		if got := kindOfLine(tc.line); got != tc.want {
			t.Errorf("%.80q: got %s, want %s", tc.line, got, tc.want)
		}
	}
}

func TestParseValues(t *testing.T) {
	cmd, err := ParseCommand(`put "ké\/" {b:[1,-2,"x\n"], "a":null, c:{d:true}}`)
	if err != nil {
		t.Fatal(err)
	}
	if string(cmd.Key) != "ké/" {
		t.Errorf("key = %q", cmd.Key)
	}
	res := RunScript(nil, nil, []byte("put \"k\" {b:[1,-2,\"x\\n\"], \"a\":null, c:{d:true}}\nget \"k\"\n"))
	want := "[1] ok put created\n[2] ok get value\n  {\"a\":null,\"b\":[1,-2,\"x\\n\"],\"c\":{\"d\":true}}\n"
	if string(res.Results) != want {
		t.Errorf("got %q\nwant %q", res.Results, want)
	}
}

func TestParsePathHelper(t *testing.T) {
	if segs, err := ParsePath("a.b_c.D9"); err != nil || len(segs) != 3 {
		t.Errorf("ParsePath: %v %v", segs, err)
	}
	for text, want := range map[string]ErrorKind{
		"": ErrSyntax, "a..b": ErrSyntax, "1a": ErrSyntax, "a.": ErrSyntax,
		"a.b.c.d.e.f.g.h.i": ErrBadPath, strings.Repeat("x", 31): ErrBadPath,
	} {
		if _, err := ParsePath(text); KindOf(err) != want {
			t.Errorf("ParsePath(%q) = %v, want %s", text, err, want)
		}
	}
}

func TestLexTokens(t *testing.T) {
	toks, err := lex(`a<=b>=c==d!=e<f>g`)
	if err != nil {
		t.Fatal(err)
	}
	var ops []string
	for _, tk := range toks {
		if tk.kind == tkOp {
			ops = append(ops, tk.text)
		}
	}
	if strings.Join(ops, " ") != "<= >= == != < >" {
		t.Errorf("ops = %v", ops)
	}
	for _, bad := range []string{"=", "!", "a = b", "#", "a\x00", "\"\x01\""} {
		if _, err := lex(bad); err == nil {
			t.Errorf("lex(%q) should fail", bad)
		}
	}
}
