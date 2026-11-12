package message

import (
	"strings"
	"testing"
)

func parse(s string) *Message { return Parse([]byte(strings.ReplaceAll(s, "⏎", "\n"))) }

func TestMultipartStructure(t *testing.T) {
	m := parse("Content-Type: multipart/mixed; boundary=X⏎⏎pre⏎--X⏎Content-Type: text/plain⏎⏎hello⏎--X⏎" +
		"Content-Type: application/octet-stream⏎Content-Disposition: attachment; filename=a.bin⏎" +
		"Content-Transfer-Encoding: base64⏎⏎AAECAw==⏎--X--⏎tail⏎")
	if len(m.Parts) != 3 {
		t.Fatalf("parts = %d", len(m.Parts))
	}
	root := m.Root
	if root.Kind != Multipart || root.Preamble != 3 || root.Epilogue != 5 || len(root.Children) != 2 {
		t.Errorf("root = %+v", root)
	}
	if m.TextBody == nil || m.TextBody.Index != 1 || string(m.TextBody.Content) != "hello" {
		t.Errorf("text body = %+v", m.TextBody)
	}
	if len(m.Attachments) != 1 || m.Attachments[0].Filename != "a.bin" ||
		string(m.Attachments[0].Content) != "\x00\x01\x02\x03" {
		t.Errorf("attachments = %+v", m.Attachments)
	}
}

func TestBoundaryEdgeCases(t *testing.T) {
	// No delimiter: the whole body is the preamble and there is no epilogue.
	m := parse("Content-Type: multipart/mixed; boundary=X⏎⏎just text⏎")
	if r := m.Root; len(r.Children) != 0 || r.Preamble != 10 || r.Epilogue != -1 {
		t.Errorf("no delimiter: %+v", r)
	}
	// Close delimiter first.
	m = parse("Content-Type: multipart/mixed; boundary=X⏎⏎--X--⏎epi")
	if r := m.Root; len(r.Children) != 0 || r.Preamble != 0 || r.Epilogue != 3 {
		t.Errorf("close first: %+v", r)
	}
	// Two delimiters in a row bound an empty part; trailing blanks are allowed;
	// an unclosed multipart runs to the end.
	m = parse("Content-Type: multipart/mixed; boundary=X⏎⏎--X ⏎--X⏎--Xjunk⏎x⏎")
	if r := m.Root; len(r.Children) != 2 || r.Epilogue != -1 {
		t.Fatalf("empty part: %+v", r)
	}
	if c := m.Root.Children[1]; string(c.Content) != "--Xjunk\nx" {
		t.Errorf("unclosed child content = %q", c.Content)
	}
	// Without a boundary a multipart is a leaf.
	m = parse("Content-Type: multipart/mixed⏎⏎body")
	if m.Root.Kind != Leaf || string(m.Root.Content) != "body" {
		t.Errorf("no boundary: %+v", m.Root)
	}
}

func TestDigestDefaultsToMessage(t *testing.T) {
	m := parse("Content-Type: multipart/digest; boundary=D⏎⏎--D⏎⏎Subject: inner⏎⏎inner body⏎--D--⏎")
	if len(m.Parts) != 3 {
		t.Fatalf("parts = %d", len(m.Parts))
	}
	c := m.Parts[1]
	if c.MediaType() != "message/rfc822" || c.Kind != MessageContainer || len(c.Children) != 1 {
		t.Errorf("digest child = %+v", c)
	}
	inner := m.Parts[2]
	if inner.MediaType() != "text/plain" || inner.Role != RoleAttachment || m.TextBody != nil {
		t.Errorf("inner = %+v, text = %v", inner, m.TextBody)
	}
}

func TestBodySelection(t *testing.T) {
	m := parse("Content-Type: multipart/alternative; boundary=B⏎⏎" +
		"--B⏎Content-Type: text/plain⏎Content-Disposition: attachment⏎⏎first⏎" +
		"--B⏎Content-Type: text/plain⏎⏎second⏎" +
		"--B⏎Content-Type: text/html⏎Content-Disposition: inline⏎⏎<p>⏎" +
		"--B⏎Content-Type: text/html⏎⏎<b>⏎--B--⏎")
	if m.TextBody == nil || m.TextBody.Index != 2 || m.HTMLBody == nil || m.HTMLBody.Index != 3 {
		t.Fatalf("bodies: %+v %+v", m.TextBody, m.HTMLBody)
	}
	if len(m.Attachments) != 2 || m.Attachments[0].Index != 1 || m.Attachments[1].Index != 4 {
		t.Errorf("attachments: %+v", m.Attachments)
	}
}

func TestContentTypeFallbacks(t *testing.T) {
	for in, want := range map[string]string{
		"":                         "text/plain",
		"Content-Type: garbage⏎":   "text/plain",
		"Content-Type: a/b/c⏎":     "text/plain",
		"Content-Type: /plain⏎":    "text/plain",
		"Content-Type: Image/PNG⏎": "image/png",
		"Content-Type: text/x y⏎":  "text/plain",
	} {
		if got := parse(in + "⏎x").Root.MediaType(); got != want {
			t.Errorf("%q: %s, want %s", in, got, want)
		}
	}
}

func TestMessageRFC822AndTextCharset(t *testing.T) {
	m := parse("Content-Type: message/rfc822⏎⏎Content-Type: text/plain; charset=iso-8859-1⏎⏎caf\xe9")
	if m.Root.Kind != MessageContainer || len(m.Parts) != 2 {
		t.Fatalf("root = %+v", m.Root)
	}
	if got := m.Parts[1].Text(); got != "café" {
		t.Errorf("text = %q", got)
	}
	if m.TextBody != nil || len(m.Attachments) != 1 {
		t.Errorf("rfc822 child must not be a body: %+v", m.TextBody)
	}
	if m.Parts[1].Charset != "iso-8859-1" {
		t.Errorf("charset = %q", m.Parts[1].Charset)
	}
}

func TestCRLFAndSize(t *testing.T) {
	raw := "Subject: x\r\n\r\nline1\r\nline2\r\n"
	m := Parse([]byte(raw))
	if m.Size != len(raw) {
		t.Errorf("size = %d, want %d", m.Size, len(raw))
	}
	if got := string(m.Root.Content); got != "line1\nline2\n" {
		t.Errorf("content = %q", got)
	}
}

func TestFilenameSources(t *testing.T) {
	m := parse("Content-Type: application/x; name=ct.bin⏎⏎x")
	if !m.Root.HasFilename || m.Root.Filename != "ct.bin" {
		t.Errorf("name param: %+v", m.Root)
	}
	m = parse("Content-Type: application/x; name=ct.bin⏎Content-Disposition: attachment; filename=cd.bin⏎⏎x")
	if m.Root.Filename != "cd.bin" {
		t.Errorf("filename should win: %q", m.Root.Filename)
	}
}

func TestAddressesAndDate(t *testing.T) {
	m := parse("To: a@b, c <d@e>⏎To: f@g⏎Date: 1 Jan 2000 00:00 GMT⏎⏎")
	if got := m.Addresses("to"); len(got) != 3 || got[2].Spec != "f@g" {
		t.Errorf("addresses = %+v", got)
	}
	raw, present, d, valid := m.Date()
	if !present || !valid || raw != " 1 Jan 2000 00:00 GMT" || d.Epoch != 946684800 {
		t.Errorf("date = %q %v %+v %v", raw, present, d, valid)
	}
	if _, present, _, _ := parse("X: 1⏎⏎").Date(); present {
		t.Error("date should be absent")
	}
}
