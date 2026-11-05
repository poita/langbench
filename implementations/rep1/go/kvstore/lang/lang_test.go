package lang

import (
	"strings"
	"testing"

	"example.com/kvstore/kverr"
	"example.com/kvstore/query"
	"example.com/kvstore/value"
)

func kind(t *testing.T, line string) string {
	t.Helper()
	_, err := Parse(line)
	return kverr.KindOf(err)
}

func TestErrorKinds(t *testing.T) {
	tests := []struct{ line, want string }{
		{``, "syntax"},
		{"  \t ", "syntax"},
		{`123`, "syntax"},
		{`PUT "a" 1`, "unknown-command"},
		{`frobnicate "\ud800"`, "unknown-command"},
		{`put "\ud800" 1`, "bad-utf8"},
		{`put "a" "\ud800A"`, "bad-utf8"},
		{`put "a" "\udc00"`, "bad-utf8"},
		{`put "a" "\u00zz"`, "syntax"},
		{`put 1 "x"`, "syntax"},
		{`put "" 1`, "bad-key"},
		{`put "` + strings.Repeat("k", 129) + `" 1`, "bad-key"},
		{`put "a" 007`, "syntax"},
		{`put "a" -0`, "syntax"},
		{`put "a" +1`, "syntax"},
		{`put "a" -`, "syntax"},
		{`put "a" 9223372036854775808`, "int-range"},
		{`put "a" -9223372036854775808`, ""},
		{`put "a" 1 99999999999999999999`, "syntax"},
		{`get "a" "\ud800"`, "syntax"},
		{`put "a" [1,]`, "syntax"},
		{`put "a" {x:1,}`, "syntax"},
		{`put "a" {x:1,x 2}`, "dup-field"},
		{`put "a" {x:1,"x":2}`, "dup-field"},
		{`put "a" "tab` + "\t" + `"`, "syntax"},
		{`put "a" "\q"`, "syntax"},
		{`put "a" "open`, "syntax"},
		{`put "a" =`, "syntax"},
		{`begin now`, "syntax"},
		{`scan limit -1`, "syntax"},
		{`scan limit 99999999999999999999`, "int-range"},
		{`scan from "a" from "b"`, "syntax"},
		{`scan bogus`, "syntax"},
		{`scan from "` + strings.Repeat("k", 300) + `"`, ""},
		{`create index`, "syntax"},
		{`create idx a`, "syntax"},
		{`create index a.b.c.d.e.f.g.h.i.`, "bad-path"},
		{`create index ` + strings.Repeat("a", 31) + `.`, "bad-path"},
		{`create index aaaaaaaaaa.bbbbbbbbbb.cccccccc`, ""},
		{`create index aaaaaaaaaa.bbbbbbbbbb.ccccccccd`, "bad-path"},
		{`find`, "syntax"},
		{`find a == `, "syntax"},
		{`find a = 1`, "syntax"},
		{`find a == 1 limit`, "syntax"},
		{`find a == 1 limit 2 3`, "syntax"},
	}
	for _, tc := range tests {
		if got := kind(t, tc.line); got != tc.want {
			t.Errorf("%q: got %q, want %q", tc.line, got, tc.want)
		}
	}
}

func TestDepthRule(t *testing.T) {
	open := strings.Repeat("[", 32)
	closed := strings.Repeat("]", 32)
	tests := []struct{ lit, want string }{
		{open + closed, ""},
		{open + "1" + closed, "depth"},
		{open + "99999999999999999999", "depth"},
		{open + `"\ud800"`, "depth"},
		{open + ",", "depth"},
		{open + ")", "depth"},
		{open, "depth"},
		{open + "-", "syntax"},
		{strings.Repeat("[", 30) + "{x:[[1]],x:1}", "depth"},
		{strings.Repeat("[", 30) + "{x:1,x:[[1]]}", "dup-field"},
	}
	for _, tc := range tests {
		if got := kind(t, "put \"a\" "+tc.lit); got != tc.want {
			t.Errorf("%.50q...: got %q, want %q", tc.lit, got, tc.want)
		}
	}
}

func TestParseValues(t *testing.T) {
	c, err := Parse(`put "k" {b: [1, "xé😀", null], a : true, "c d": {}}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := value.Render(c.Value); got != `{"a":true,"b":[1,"xé😀",null],"c d":{}}` {
		t.Fatalf("got %s", got)
	}
	if string(c.Key) != "k" {
		t.Fatalf("key %q", c.Key)
	}
}

func TestScanOptions(t *testing.T) {
	c, err := Parse(`scan reverse limit 3 from "a" to "z" keys`)
	if err != nil {
		t.Fatal(err)
	}
	o := c.Scan
	if !o.HasFrom || !o.HasTo || string(o.From) != "a" || string(o.To) != "z" || o.Limit != 3 || !o.Reverse || !o.KeyOnly {
		t.Fatalf("%+v", o)
	}
	c, _ = Parse(`scan`)
	if c.Scan.Limit != -1 || c.Scan.HasFrom {
		t.Fatalf("defaults: %+v", c.Scan)
	}
}

func TestPredicates(t *testing.T) {
	c, err := Parse(`find a == 1 or b > 2 and not(c.d != "x") and exists e and missing f limit 5`)
	if err != nil {
		t.Fatal(err)
	}
	if c.Limit != 5 {
		t.Fatalf("limit %d", c.Limit)
	}
	or, ok := c.Pred.(query.Or)
	if !ok {
		t.Fatalf("root is %T, want Or (and binds tighter)", c.Pred)
	}
	if got := len(query.Leaves(or.R)); got != 4 {
		t.Fatalf("right side flattens to %d leaves, want 4", got)
	}

	// Keywords are valid field names when the grammar says "path".
	for _, line := range []string{
		`find not == 1`, `find exists == 1`, `find missing >= 2`, `find and == 1`,
		`find (a == 1)`, `find a.b.c <= null`,
	} {
		if k := kind(t, line); k != "" {
			t.Errorf("%q: %s", line, k)
		}
	}
	if k := kind(t, `find not a == 1`); k != "syntax" {
		t.Errorf("not without parens: %q", k)
	}
	if k := kind(t, `find (a == 1`); k != "syntax" {
		t.Errorf("unclosed paren: %q", k)
	}
}
