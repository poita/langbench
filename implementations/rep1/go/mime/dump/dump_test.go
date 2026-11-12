package dump

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"example.com/mime/mailbox"
	"example.com/mime/message"
)

func TestEscape(t *testing.T) {
	for in, want := range map[string]string{
		"plain":         "plain",
		"a\\b":          `a\\b`,
		"l1\nl2\r\tq\"": `l1\nl2\r\tq\"`,
		"\x00\x1f\x7f":  `\x00\x1f\x7f`,
		"\u0080\u009f":  `\x80\x9f`,
		" é€�":          " é€�",
		" ":             " ",
	} {
		if got := Escape(in); got != want {
			t.Errorf("Escape(%q) = %q, want %q", in, got, want)
		}
	}
	if got := Quote(`a"b`); got != `"a\"b"` {
		t.Errorf("Quote = %s", got)
	}
}

const worked = "From nobody Mon Sep  1 00:00:00 2025\n" +
	"Subject: =?utf-8?Q?Caf=C3=A9?= report\n" +
	"From: Ann Example <ann@example.com>\n" +
	"To: bob@example.org, Carl <carl@example.org>\n" +
	"Date: Mon, 1 Sep 2025 12:30:00 +0200\n" +
	"MIME-Version: 1.0\n" +
	"Content-Type: multipart/mixed; boundary=\"X\"\n\n" +
	"ignore me\n--X\n" +
	"Content-Type: text/plain; charset=iso-8859-1\n\ncaf\xe9\n--X\n" +
	"Content-Type: application/octet-stream\n" +
	"Content-Disposition: attachment; filename=\"a.bin\"\n" +
	"Content-Transfer-Encoding: base64\n\nAAECAw==\n--X--\n\n"

const wantMessage = `[message]
id 0001
source "mbox:1"

[headers]
subject: "Café report"
from: "Ann Example <ann@example.com>"
to: "bob@example.org, Carl <carl@example.org>"
date: "Mon, 1 Sep 2025 12:30:00 +0200"
mime-version: "1.0"
content-type: "multipart/mixed; boundary=\"X\""

[addresses]
from 0 display="Ann Example" spec="ann@example.com"
to 0 display="" spec="bob@example.org"
to 1 display="Carl" spec="carl@example.org"

[date]
raw " Mon, 1 Sep 2025 12:30:00 +0200"
valid yes
utc 2025-09-01T10:30:00Z
offset +0200
epoch 1756722600

[structure]
0 multipart/mixed cte=7bit boundary="X" parts=2 preamble=9 epilogue=0
  1 text/plain charset=iso-8859-1 cte=7bit size=4 adler32=04680214 role=text
  2 application/octet-stream cte=base64 disposition=attachment filename="a.bin" size=4 adler32=000e0007 role=attachment

[body]
text 1 chars 4
| café
html none

[attachments]
2 type=application/octet-stream filename="a.bin" size=4 adler32=000e0007 file=parts/0001/002.bin
`

func TestWorkedExample(t *testing.T) {
	srcs := mailbox.SplitMbox([]byte(worked))
	if len(srcs) != 1 || len(srcs[0]) != 427 {
		t.Fatalf("split: %d messages", len(srcs))
	}
	m := message.Parse(srcs[0])
	if got := Render(1, "mbox:1", m); got != wantMessage {
		t.Errorf("Render mismatch:\n%s\nwant:\n%s", got, wantMessage)
	}
	wantSummary := `0001 source="mbox:1" bytes=427 parts=3 attachments=1 text=1 html=-`
	if got := SummaryLine(1, "mbox:1", m); got != wantSummary {
		t.Errorf("summary = %q", got)
	}
}

func TestBodyLines(t *testing.T) {
	for in, want := range map[string]string{
		"a\nb\n": "| a\n| b\n",
		"a\n\n":  "| a\n| \n",
		"a":      "| a\n",
		"":       "",
	} {
		m := message.Parse([]byte("Content-Type: text/plain\n\n" + in))
		var b strings.Builder
		body(&b, "text", m.TextBody)
		lines := b.String()
		lines = lines[strings.IndexByte(lines, '\n')+1:]
		if lines != want {
			t.Errorf("body %q rendered %q, want %q", in, lines, want)
		}
	}
}

func TestWriteAll(t *testing.T) {
	out := t.TempDir()
	srcs := []mailbox.Source{{ID: "mbox:1", Data: mailbox.SplitMbox([]byte(worked))[0]}}
	if err := WriteAll(out, srcs); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(out, "parts", "0001", "002.bin"))
	if err != nil || string(got) != "\x00\x01\x02\x03" {
		t.Errorf("attachment = %q, %v", got, err)
	}
	sum, _ := os.ReadFile(filepath.Join(out, "summary.txt"))
	if !strings.HasPrefix(string(sum), "messages 1\n0001 ") {
		t.Errorf("summary = %q", sum)
	}
	msg, _ := os.ReadFile(filepath.Join(out, "messages", "0001.txt"))
	if string(msg) != wantMessage {
		t.Error("message file differs")
	}
	// A message without attachments creates no parts directory.
	out2 := t.TempDir()
	if err := WriteAll(out2, []mailbox.Source{{ID: "x.eml", Data: []byte("Subject: hi\n\nbody\n")}}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(out2, "parts")); err == nil {
		t.Error("parts directory should not exist")
	}
}
