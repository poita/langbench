package toml

import (
	"reflect"
	"strings"
	"testing"
)

func TestParseSpecExample(t *testing.T) {
	src := `# a comment
title  = "The \"Big\" Blog"        # trailing comment
posts_per_page = 5
draft = false
tags = ["one", "two",]
motto = "line one\nline two"
`
	d, err := Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	if s, _ := d.String("title"); s != `The "Big" Blog` {
		t.Errorf("title = %q", s)
	}
	if n, _ := d.Int("posts_per_page"); n != 5 {
		t.Errorf("posts_per_page = %d", n)
	}
	if b, ok := d.Bool("draft"); !ok || b {
		t.Errorf("draft = %v, %v", b, ok)
	}
	if a, _ := d.Strings("tags"); !reflect.DeepEqual(a, []string{"one", "two"}) {
		t.Errorf("tags = %q", a)
	}
	if s, _ := d.String("motto"); s != "line one\nline two" {
		t.Errorf("motto = %q", s)
	}
	var keys []string
	for _, e := range d.Entries() {
		keys = append(keys, e.Key)
	}
	if want := []string{"title", "posts_per_page", "draft", "tags", "motto"}; !reflect.DeepEqual(keys, want) {
		t.Errorf("keys = %q, want %q", keys, want)
	}
}

func TestValues(t *testing.T) {
	tests := []struct {
		in   string
		want Value
	}{
		{`k = "x"`, Value{Kind: String, Str: "x"}},
		{`k = ""`, Value{Kind: String}},
		{`k = "a # b"  # c`, Value{Kind: String, Str: "a # b"}},
		{`k = "\\ \" \n \t \r"`, Value{Kind: String, Str: "\\ \" \n \t \r"}},
		{`k = "éÉ中"`, Value{Kind: String, Str: "éÉ中"}},
		{`k = "é 中 ' #"`, Value{Kind: String, Str: "é 中 ' #"}},
		{`k = 0`, Value{Kind: Integer}},
		{`k = -4`, Value{Kind: Integer, Int: -4}},
		{`k = 9223372036854775807`, Value{Kind: Integer, Int: 9223372036854775807}},
		{`k = -9223372036854775808`, Value{Kind: Integer, Int: -9223372036854775808}},
		{`k = true`, Value{Kind: Boolean, Bool: true}},
		{`k = false # no`, Value{Kind: Boolean}},
		{`k = []`, Value{Kind: Array, Strings: []string{}}},
		{`k = [ ]`, Value{Kind: Array, Strings: []string{}}},
		{`k = ["a"]`, Value{Kind: Array, Strings: []string{"a"}}},
		{`k = [ "a" , "b,c" ,]`, Value{Kind: Array, Strings: []string{"a", "b,c"}}},
		{"k\t=\t\"x\"\t#c", Value{Kind: String, Str: "x"}},
		{"  k-1_a=1", Value{Kind: Integer, Int: 1}},
	}
	for _, tc := range tests {
		d, err := Parse(tc.in)
		if err != nil {
			t.Errorf("Parse(%q): %v", tc.in, err)
			continue
		}
		key := strings.TrimSpace(tc.in)
		key = key[:strings.IndexAny(key, " \t=")]
		got, _ := d.Get(key)
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("Parse(%q) = %+v, want %+v", tc.in, got, tc.want)
		}
	}
}

func TestBlankAndComments(t *testing.T) {
	d, err := Parse("\n  \t \n# c\n\t# d\na = 1\n\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Entries()) != 1 {
		t.Errorf("entries = %v", d.Entries())
	}
	if d, err := Parse(""); err != nil || len(d.Entries()) != 0 {
		t.Errorf("empty document: %v, %v", d, err)
	}
}

func TestErrors(t *testing.T) {
	for _, in := range []string{
		`k`, `k =`, `= 1`, `k = bare`, `k = 01`, `k = +1`, `k = 1_0`, `k = 1.5`,
		`k = "open`, `k = "bad \q"`, `k = "\u12"`, `k = "\uZZZZ"`,
		`k = [1]`, `k = ["a" "b"]`, `k = ["a"`, `k = "a" x`, `k = 1 2`,
		`[table]`, `a.b = 1`, "k = 1\nk = 2", `k = 99999999999999999999`,
	} {
		if _, err := Parse(in); err == nil {
			t.Errorf("Parse(%q) succeeded, want an error", in)
		}
	}
	_, err := Parse("a = 1\nb = ?")
	if se, ok := err.(*SyntaxError); !ok || se.Line != 2 {
		t.Errorf("error = %v, want a SyntaxError on line 2", err)
	}
}

func TestGetTypes(t *testing.T) {
	d, _ := Parse(`s = "x"` + "\n" + `n = 1`)
	if _, ok := d.Int("s"); ok {
		t.Error("Int of a string succeeded")
	}
	if _, ok := d.String("n"); ok {
		t.Error("String of an integer succeeded")
	}
	if _, ok := d.Get("missing"); ok {
		t.Error("Get of a missing key succeeded")
	}
	if Array.String() != "array" || Kind(99).String() != "unknown" {
		t.Error("Kind.String")
	}
}
