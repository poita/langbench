package main

import (
	"bytes"
	"strings"
	"testing"
)

func runString(t *testing.T, in string) string {
	t.Helper()
	var out bytes.Buffer
	if err := run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

func TestDecode(t *testing.T) {
	got := runString(t, "decode\na = 1\n")
	if want := "{\"a\":{\"type\":\"integer\",\"value\":\"1\"}}\n"; got != want {
		t.Errorf("got %q want %q", got, want)
	}
	if got := runString(t, "decode\na = \n"); got != "error\n" {
		t.Errorf("got %q", got)
	}
	if got := runString(t, "decode\n"); got != "{}\n" {
		t.Errorf("got %q", got)
	}
}

func TestEncode(t *testing.T) {
	got := runString(t, "encode\n{\"a\":{\"type\":\"string\",\"value\":\"x\"}}")
	if want := "a = \"x\"\n"; got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestBadMode(t *testing.T) {
	var out bytes.Buffer
	if err := run(strings.NewReader("bogus\n"), &out); err == nil {
		t.Error("expected error")
	}
}
