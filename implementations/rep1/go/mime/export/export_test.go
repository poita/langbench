package export

import (
	"os"
	"path/filepath"
	"testing"

	"mimedump/mailbox"
)

func TestWrite(t *testing.T) {
	mbox := "From x\nSubject: one\nContent-Type: application/octet-stream\nContent-Transfer-Encoding: base64\n\nAAEC\n\nFrom y\nSubject: two\n\nhi\n"
	mb := mailbox.FromMbox([]byte(mbox))
	out := filepath.Join(t.TempDir(), "out")
	if err := Write(mb, out); err != nil {
		t.Fatal(err)
	}
	summary, err := os.ReadFile(filepath.Join(out, "summary.txt"))
	if err != nil {
		t.Fatal(err)
	}
	want := "messages 2\n" +
		"0001 source=\"mbox:1\" bytes=" + "92" + " parts=1 attachments=1 text=- html=-\n" +
		"0002 source=\"mbox:2\" bytes=" + "17" + " parts=1 attachments=0 text=0 html=-\n"
	if string(summary) != want {
		t.Errorf("summary:\n%s\nwant:\n%s", summary, want)
	}
	bin, err := os.ReadFile(filepath.Join(out, "parts", "0001", "000.bin"))
	if err != nil || string(bin) != "\x00\x01\x02" {
		t.Errorf("attachment = %q, %v", bin, err)
	}
	if _, err := os.Stat(filepath.Join(out, "parts", "0002")); err == nil {
		t.Error("parts/0002 must not exist")
	}
	if _, err := os.Stat(filepath.Join(out, "messages", "0002.txt")); err != nil {
		t.Error(err)
	}
}
