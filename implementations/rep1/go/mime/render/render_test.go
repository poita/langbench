package render

import (
	"strings"
	"testing"

	"mimedump/message"
)

func TestEsc(t *testing.T) {
	cases := []struct{ in, want string }{
		{"plain", "plain"},
		{"a\\b\n\r\t\"", `a\\b\n\r\t\"`},
		{"\x00\x1f\x7f", `\x00\x1f\x7f`},
		{"\u0080\u009f é", `\x80\x9f` + " é"},
		{"日本", "日本"},
	}
	for _, c := range cases {
		if got := Esc(c.in); got != c.want {
			t.Errorf("Esc(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	if Quote("a\"") != `"a\""` {
		t.Error("Quote")
	}
}

const worked = "Subject: =?utf-8?Q?Caf=C3=A9?= report\n" +
	"From: Ann Example <ann@example.com>\n" +
	"To: bob@example.org, Carl <carl@example.org>\n" +
	"Date: Mon, 1 Sep 2025 12:30:00 +0200\n" +
	"MIME-Version: 1.0\n" +
	"Content-Type: multipart/mixed; boundary=\"X\"\n" +
	"\n" +
	"ignore me\n" +
	"--X\n" +
	"Content-Type: text/plain; charset=iso-8859-1\n" +
	"\n" +
	"caf\xe9\n" +
	"--X\n" +
	"Content-Type: application/octet-stream\n" +
	"Content-Disposition: attachment; filename=\"a.bin\"\n" +
	"Content-Transfer-Encoding: base64\n" +
	"\n" +
	"AAECAw==\n" +
	"--X--\n"

const wantDump = `[message]
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
	m := message.Parse([]byte(worked))
	if got := string(Message(1, "mbox:1", m)); got != wantDump {
		t.Errorf("dump mismatch:\n%s\nwant:\n%s", got, wantDump)
	}
	want := `0001 source="mbox:1" bytes=427 parts=3 attachments=1 text=1 html=-`
	if got := SummaryLine(1, "mbox:1", 427, m); got != want {
		t.Errorf("summary = %q", got)
	}
}

func TestBodyLines(t *testing.T) {
	for text, want := range map[string]string{
		"a\nb\n": "| a\n| b\n",
		"a\n\n":  "| a\n| \n",
		"a":      "| a\n",
		"":       "",
		"\n":     "| \n",
	} {
		m := message.Parse([]byte("Content-Type: text/plain\n\n" + text))
		got := string(Message(1, "x", m))
		i := strings.Index(got, "[body]\n")
		j := strings.Index(got, "html none")
		body := got[i+len("[body]\n") : j]
		body = body[strings.Index(body, "\n")+1:]
		if body != want {
			t.Errorf("text %q: body lines %q, want %q", text, body, want)
		}
	}
}

func TestNoDateNoParts(t *testing.T) {
	got := string(Message(7, "f.eml", message.Parse(nil)))
	if !strings.Contains(got, "[date]\nnone\n") || !strings.Contains(got, "[headers]\n\n[addresses]\n\n") {
		t.Errorf("empty message dump:\n%s", got)
	}
	if !strings.HasSuffix(got, "[attachments]\n") {
		t.Errorf("must end after attachments marker:\n%s", got)
	}
}

func TestAttachmentPath(t *testing.T) {
	if AttachmentPath(12, 3) != "parts/0012/003.bin" {
		t.Error(AttachmentPath(12, 3))
	}
}
