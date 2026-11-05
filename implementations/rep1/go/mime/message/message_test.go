package message

import (
	"strings"
	"testing"
)

func crlf(s string) []byte { return []byte(strings.ReplaceAll(s, "\n", "\r\n")) }

const worked = "Subject: x\n" +
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

func TestMultipart(t *testing.T) {
	m := Parse([]byte(worked))
	if len(m.Parts) != 3 {
		t.Fatalf("parts = %d", len(m.Parts))
	}
	root := m.Parts[0]
	if root.Kind != Multipart || root.Boundary != "X" || root.Preamble != 9 || root.Epilogue != 0 || len(root.Children) != 2 {
		t.Errorf("root = %+v", root)
	}
	text := m.Parts[1]
	if text.Text != "café" || text.Chars != 4 || text.Adler32 != 0x04680214 || text.Role != RoleText {
		t.Errorf("text part = %+v", text)
	}
	att := m.Parts[2]
	if string(att.Content) != "\x00\x01\x02\x03" || att.Filename != "a.bin" || att.Role != RoleAttachment {
		t.Errorf("attachment = %+v", att)
	}
	if m.Text != text || m.HTML != nil || len(m.Attachments) != 1 || m.Attachments[0] != att {
		t.Error("body selection")
	}
}

func TestCRLFEquivalent(t *testing.T) {
	a, b := Parse([]byte(worked)), Parse(crlf(worked))
	if len(a.Parts) != len(b.Parts) || a.Parts[1].Adler32 != b.Parts[1].Adler32 {
		t.Error("CRLF input must parse like LF input")
	}
}

func TestDefaultsAndDigest(t *testing.T) {
	m := Parse([]byte("Content-Type: multipart/digest; boundary=b\n\n--b\n\nSubject: inner\n\nhi\n--b\nContent-Type: bogus\n\nx\n--b--\n"))
	if m.Parts[1].Type != "message" || m.Parts[1].Subtype != "rfc822" || m.Parts[1].Kind != MessageEnv {
		t.Errorf("digest child = %+v", m.Parts[1])
	}
	if m.Parts[2].Type != "text" || m.Parts[2].Subtype != "plain" || m.Parts[2].Charset != "us-ascii" {
		t.Errorf("inner = %+v", m.Parts[2])
	}
	if m.Parts[3].Type != "message" {
		t.Errorf("bogus type in a digest falls back to message/rfc822, got %s/%s", m.Parts[3].Type, m.Parts[3].Subtype)
	}
}

func TestDegenerateMultipart(t *testing.T) {
	// no delimiter at all
	m := Parse([]byte("Content-Type: multipart/mixed; boundary=b\n\nplain body\n"))
	p := m.Parts[0]
	if len(m.Parts) != 1 || p.Preamble != 11 || p.Epilogue != -1 || len(p.Children) != 0 {
		t.Errorf("no delimiter: %+v", p)
	}
	// close delimiter first
	m = Parse([]byte("Content-Type: multipart/mixed; boundary=b\n\n--b--\nrest\n"))
	if p = m.Parts[0]; p.Preamble != 0 || p.Epilogue != 5 || len(p.Children) != 0 {
		t.Errorf("close first: %+v", p)
	}
	// adjacent delimiters give an empty child; no close delimiter keeps the rest
	m = Parse([]byte("Content-Type: multipart/mixed; boundary=b\n\n--b\n--b  \t\nlast\n"))
	if len(m.Parts) != 3 || len(m.Parts[1].Content) != 0 || string(m.Parts[2].Content) != "last" || m.Parts[0].Epilogue != -1 {
		t.Errorf("adjacent: %d parts", len(m.Parts))
	}
	// multipart without boundary is a leaf
	m = Parse([]byte("Content-Type: multipart/mixed\n\nbody"))
	if m.Parts[0].Kind != Leaf || m.Parts[0].Role != RoleAttachment {
		t.Errorf("multipart without boundary: %+v", m.Parts[0])
	}
}

func TestRFC822AndSelection(t *testing.T) {
	src := "Content-Type: message/rfc822\n\nSubject: in\nContent-Type: text/plain\n\ninner body\n"
	m := Parse([]byte(src))
	if m.Parts[0].Kind != MessageEnv || len(m.Parts[0].Children) != 1 || len(m.Parts) != 2 {
		t.Fatalf("structure: %+v", m.Parts[0])
	}
	// The inner text part is not a body candidate: it is an attachment.
	if m.Text != nil || len(m.Attachments) != 1 || m.Attachments[0].Index != 1 {
		t.Errorf("selection: text=%v attachments=%d", m.Text, len(m.Attachments))
	}
}

func TestAttachmentDispositionSkipsBody(t *testing.T) {
	src := "Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: text/plain\nContent-Disposition: attachment\n\none\n--b\nContent-Type: text/plain\nContent-Disposition: inline\n\ntwo\n--b\nContent-Type: text/html\n\n<p>\n--b--\n"
	m := Parse([]byte(src))
	if m.Text == nil || m.Text.Index != 2 || m.HTML == nil || m.HTML.Index != 3 || len(m.Attachments) != 1 || m.Attachments[0].Index != 1 {
		t.Errorf("selection wrong: %+v", m)
	}
}

func TestFilenameFallbackAndCharsetNormalisation(t *testing.T) {
	m := Parse([]byte("Content-Type: text/plain; name=\"n.txt\"; charset= UTF-8 \n\nx"))
	p := m.Parts[0]
	if !p.HasFilename || p.Filename != "n.txt" || p.Charset != "utf-8" {
		t.Errorf("part = %+v", p)
	}
	m = Parse([]byte("Content-Type: text/plain; name=\"n.txt\"\nContent-Disposition: attachment; filename=\"d.txt\"\n\nx"))
	if m.Parts[0].Filename != "d.txt" {
		t.Errorf("disposition filename must win, got %q", m.Parts[0].Filename)
	}
}

func TestInvalidContentTypeFallsBack(t *testing.T) {
	for _, ct := range []string{"nonsense", "a/", "/b", "a b/c", "a/b/c", ""} {
		m := Parse([]byte("Content-Type: " + ct + "; charset=x\n\nbody"))
		if p := m.Parts[0]; p.Type != "text" || p.Subtype != "plain" || p.Charset != "x" {
			t.Errorf("%q: %s/%s charset=%q", ct, p.Type, p.Subtype, p.Charset)
		}
	}
}
