package mailbox

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func strs(bs [][]byte) []string {
	out := make([]string, len(bs))
	for i, b := range bs {
		out[i] = string(b)
	}
	return out
}

func TestSplitMbox(t *testing.T) {
	tests := []struct {
		name, in string
		want     []string
	}{
		{"empty", "", []string{}},
		{"no separator", "Subject: x\n\nbody\n", []string{}},
		{"one", "From a\nS: 1\n\nbody\n\n", []string{"S: 1\n\nbody\n"}},
		{"two", "From a\nA\n\nFrom b\nB\n", []string{"A\n", "B\n"}},
		{"preamble discarded", "junk\n\nFrom a\nA\n", []string{"A\n"}},
		{"separator needs blank line", "From a\nA\nFrom b\nstill A\n", []string{"A\nFrom b\nstill A\n"}},
		{"no trailing blank", "From a\nA", []string{"A"}},
		{"only last LF dropped", "From a\nA\n\n\n", []string{"A\n\n"}},
		{"separator at eof", "From a\nA\n\nFrom b", []string{"A\n", ""}},
		{"crlf: only LF LF is trimmed", "From a\r\nA\r\n\r\nFrom b\r\nB\r\n", []string{"A\r\n\r\n", "B\r\n"}},
		{"from without space", "From\nA\n", []string{}},
	}
	for _, tc := range tests {
		got := strs(SplitMbox([]byte(tc.in)))
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestLoad(t *testing.T) {
	dir := t.TempDir()
	for name, content := range map[string]string{
		"b.eml": "B", "a.eml": "A", "Z.eml": "Z", "c.EML": "x", "d.txt": "x", "e.eml.bak": "x",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(dir, "sub.eml"), 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, s := range got {
		ids = append(ids, s.ID+"="+string(s.Data))
	}
	if want := []string{"Z.eml=Z", "a.eml=A", "b.eml=B"}; !reflect.DeepEqual(ids, want) {
		t.Errorf("got %v, want %v", ids, want)
	}

	mb := filepath.Join(t.TempDir(), "box")
	if err := os.WriteFile(mb, []byte("From x\nA\n\nFrom y\nB\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err = Load(mb)
	if err != nil || len(got) != 2 || got[0].ID != "mbox:1" || got[1].ID != "mbox:2" {
		t.Errorf("mbox load = %v, %v", got, err)
	}
	if _, err := Load(filepath.Join(dir, "missing")); err == nil {
		t.Error("expected an error for a missing path")
	}
}
