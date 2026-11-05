package mailbox

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFromMbox(t *testing.T) {
	data := "junk\n\nFrom a\nS: 1\n\nbody\n\nFrom b\nS: 2\n\n\nFrom c\r\nS: 3\n"
	mb := FromMbox([]byte(data))
	want := []string{"S: 1\n\nbody\n", "S: 2\n\n", "S: 3\n"}
	if mb.Len() != len(want) {
		t.Fatalf("Len = %d, want %d", mb.Len(), len(want))
	}
	for i, w := range want {
		got, _ := mb.Message(i)
		if string(got) != w {
			t.Errorf("message %d = %q, want %q", i, got, w)
		}
	}
	if mb.SourceID(2) != "mbox:3" {
		t.Errorf("SourceID = %q", mb.SourceID(2))
	}
}

func TestMboxSeparatorRules(t *testing.T) {
	// "From " not preceded by an empty line is body text.
	mb := FromMbox([]byte("From a\nx\nFrom not a separator\n\nFrom b\ny\n"))
	if mb.Len() != 2 {
		t.Fatalf("Len = %d", mb.Len())
	}
	if m, _ := mb.Message(0); string(m) != "x\nFrom not a separator\n" {
		t.Errorf("message 0 = %q", m)
	}
	if FromMbox([]byte("no separator\nhere\n")).Len() != 0 {
		t.Error("no separator means no messages")
	}
	if FromMbox([]byte("From a\n")).Len() != 1 {
		t.Error("a lone separator is an empty message")
	}
	// CRLF-only empty line counts as empty before a separator.
	mb = FromMbox([]byte("From a\r\nx\r\n\r\nFrom b\r\ny"))
	if mb.Len() != 2 {
		t.Errorf("CRLF mbox Len = %d", mb.Len())
	}
}

func TestOpenDirectory(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{"b.eml": "B", "Z.eml": "Z", "a.eml": "A", "skip.txt": "no", "c.EML": "no"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(dir, "d.eml"), 0o755); err != nil {
		t.Fatal(err)
	}
	mb, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"Z.eml", "a.eml", "b.eml"}
	if mb.Len() != 3 {
		t.Fatalf("Len = %d", mb.Len())
	}
	for i, w := range want {
		if mb.SourceID(i) != w {
			t.Errorf("SourceID(%d) = %q, want %q", i, mb.SourceID(i), w)
		}
	}
	if m, _ := mb.Message(0); string(m) != "Z" {
		t.Errorf("Message(0) = %q", m)
	}
}
