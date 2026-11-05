package toml

import (
	"reflect"
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
	doc, err := Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	if s, _ := doc.String("title"); s != `The "Big" Blog` {
		t.Errorf("title = %q", s)
	}
	if n, ok := doc.Int("posts_per_page"); !ok || n != 5 {
		t.Errorf("posts_per_page = %d, %v", n, ok)
	}
	if b, ok := doc.Bool("draft"); !ok || b {
		t.Errorf("draft = %v, %v", b, ok)
	}
	if a, _ := doc.Strings("tags"); !reflect.DeepEqual(a, []string{"one", "two"}) {
		t.Errorf("tags = %q", a)
	}
	if s, _ := doc.String("motto"); s != "line one\nline two" {
		t.Errorf("motto = %q", s)
	}
	var keys []string
	for _, e := range doc.Entries {
		keys = append(keys, e.Key)
	}
	if want := []string{"title", "posts_per_page", "draft", "tags", "motto"}; !reflect.DeepEqual(keys, want) {
		t.Errorf("keys = %v, want %v", keys, want)
	}
}

func TestStrings(t *testing.T) {
	tests := []struct{ src, want string }{
		{`k = "a#b"`, "a#b"},
		{`k = "tab\there"`, "tab\there"},
		{`k = "éÉ"`, "éÉ"},
		{`k = "back\\slash"`, `back\slash`},
		{`k = "cr\r"`, "cr\r"},
		{`k = "ünï 'q'"`, "ünï 'q'"},
		{`k = ""`, ""},
	}
	for _, tc := range tests {
		doc, err := Parse(tc.src)
		if err != nil {
			t.Errorf("%s: %v", tc.src, err)
			continue
		}
		if got, _ := doc.String("k"); got != tc.want {
			t.Errorf("%s: got %q want %q", tc.src, got, tc.want)
		}
	}
}

func TestIntegers(t *testing.T) {
	for src, want := range map[string]int64{"k = 0": 0, "k = -4": -4, "k = 123": 123, "k=9223372036854775807": 9223372036854775807} {
		doc, err := Parse(src)
		if err != nil {
			t.Fatalf("%s: %v", src, err)
		}
		if n, _ := doc.Int("k"); n != want {
			t.Errorf("%s: got %d", src, n)
		}
	}
}

func TestArrays(t *testing.T) {
	tests := map[string][]string{
		`k = []`:                   {},
		`k = [ ]`:                  {},
		`k = [ "a" , "b" ,  ]`:     {"a", "b"},
		`k = ["a,b", "c]"] # tail`: {"a,b", "c]"},
		"k = [\"x\"]\t \t":         {"x"},
		`k = ["a","b","c"]`:        {"a", "b", "c"},
		`  k	=	["\"", "\\"]`:       {`"`, `\`},
	}
	for src, want := range tests {
		doc, err := Parse(src)
		if err != nil {
			t.Errorf("%s: %v", src, err)
			continue
		}
		got, _ := doc.Strings("k")
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: got %q want %q", src, got, want)
		}
	}
}

func TestBlankAndCommentLines(t *testing.T) {
	doc, err := Parse("\n   \t\n  # note\na = true\n\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(doc.Entries) != 1 {
		t.Fatalf("entries = %v", doc.Entries)
	}
	if b, _ := doc.Bool("a"); !b {
		t.Error("a should be true")
	}
	empty, err := Parse("")
	if err != nil || len(empty.Entries) != 0 {
		t.Errorf("empty: %v %v", empty, err)
	}
}

func TestErrors(t *testing.T) {
	bad := []string{
		`k`, `k =`, `= 1`, `k = 01`, `k = +1`, `k = "unterminated`, `k = "a" b`,
		`k = [1]`, `k = ["a" "b"]`, `k = "\q"`, `k = "\u12"`, `k = tru`, `[table]`,
		"a = 1\na = 2", `k = "\ud800"`, `k = 99999999999999999999`, `k = ["a"`,
	}
	for _, src := range bad {
		if _, err := Parse(src); err == nil {
			t.Errorf("%q: expected an error", src)
		}
	}
	_, err := Parse("a = 1\nb")
	if se, ok := err.(*SyntaxError); !ok || se.Line != 2 {
		t.Errorf("error = %#v", err)
	}
}

func TestLookup(t *testing.T) {
	doc, _ := Parse(`a = 1`)
	if _, ok := doc.Lookup("zz"); ok {
		t.Error("unexpected key")
	}
	if _, ok := doc.String("a"); ok {
		t.Error("a is not a string")
	}
	if Integer.String() != "integer" {
		t.Error("kind name")
	}
}
