package main

import (
	"bytes"
	"strings"
	"testing"
)

func runString(t *testing.T, in string) (string, string, error) {
	t.Helper()
	var out, warn bytes.Buffer
	err := run(strings.NewReader(in), &out, &warn)
	return out.String(), warn.String(), err
}

func TestRunExample(t *testing.T) {
	out, _, err := runString(t, `{
	  "schema": {"type": "integer", "minimum": 1},
	  "tests": [
	    {"description": "a positive integer", "data": 3},
	    {"description": "zero", "data": 0},
	    {"description": "a string", "data": "3"}
	  ]}`)
	if err != nil {
		t.Fatal(err)
	}
	if want := "valid\ninvalid\ninvalid\n"; out != want {
		t.Errorf("output %q, want %q", out, want)
	}
}

func TestRunRemotesAndExtraMembers(t *testing.T) {
	out, _, err := runString(t, `{
	  "extra": [1,2,3],
	  "schema": {"$id": "http://localhost:1234/a/root.json", "$ref": "int.json"},
	  "remotes": {"http://localhost:1234/a/int.json": {"type": "integer"}},
	  "tests": [{"description": "ok", "data": 1}, {"description": "bad", "data": "x"}]}`)
	if err != nil {
		t.Fatal(err)
	}
	if out != "valid\ninvalid\n" {
		t.Errorf("output %q", out)
	}
}

func TestRunNoTests(t *testing.T) {
	out, _, err := runString(t, `{"schema": true, "tests": []}`)
	if err != nil || out != "" {
		t.Errorf("out=%q err=%v", out, err)
	}
}

func TestRunUnresolvableReferenceIsInvalidWithWarning(t *testing.T) {
	out, warn, err := runString(t, `{"schema": {"$ref": "http://nowhere/x"}, "tests": [{"description":"d","data": 1}]}`)
	if err != nil || out != "invalid\n" || warn == "" {
		t.Errorf("out=%q warn=%q err=%v", out, warn, err)
	}
}

func TestRunRejectsMalformedRequests(t *testing.T) {
	for _, in := range []string{``, `[`, `[]`, `{"tests":[]}`, `{"schema":true}`, `{"schema":true,"tests":{}}`} {
		if _, _, err := runString(t, in); err == nil {
			t.Errorf("run(%q) succeeded, want error", in)
		}
	}
}
