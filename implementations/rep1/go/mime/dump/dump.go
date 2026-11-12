// Package dump renders parsed messages as the normalised text dump and writes
// the dump and the attachments into an output directory.
package dump

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"example.com/mime/checksum"
	"example.com/mime/mailbox"
	"example.com/mime/message"
)

// Escape implements esc(s): backslash, LF, CR, TAB and double quote are
// backslash-escaped, other control characters (below 0x20, 0x7F and
// 0x80-0x9F) become \xHH, and everything else is kept.
func Escape(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	for _, r := range s {
		switch {
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '"':
			b.WriteString(`\"`)
		case r < 0x20 || r == 0x7F || (r >= 0x80 && r <= 0x9F):
			fmt.Fprintf(&b, `\x%02x`, r)
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// Quote implements q(s): the escaped string between double quotes.
func Quote(s string) string { return `"` + Escape(s) + `"` }

// MessageName returns the four-digit message number.
func MessageName(n int) string { return fmt.Sprintf("%04d", n) }

// AttachmentPath returns the output-relative path of an attachment's bytes.
func AttachmentPath(msgNum, partIndex int) string {
	return fmt.Sprintf("parts/%04d/%03d.bin", msgNum, partIndex)
}

// SummaryLine returns the summary.txt line of message number n.
func SummaryLine(n int, source string, m *message.Message) string {
	text, html := "-", "-"
	if m.TextBody != nil {
		text = fmt.Sprint(m.TextBody.Index)
	}
	if m.HTMLBody != nil {
		html = fmt.Sprint(m.HTMLBody.Index)
	}
	return fmt.Sprintf("%s source=%s bytes=%d parts=%d attachments=%d text=%s html=%s",
		MessageName(n), Quote(source), m.Size, len(m.Parts), len(m.Attachments), text, html)
}

var addressHeaders = []string{"from", "sender", "reply-to", "to", "cc", "bcc"}

// Render returns the contents of messages/NNNN.txt for message number n.
func Render(n int, source string, m *message.Message) string {
	var b strings.Builder
	line := func(format string, args ...any) {
		fmt.Fprintf(&b, format, args...)
		b.WriteByte('\n')
	}

	line("[message]")
	line("id %s", MessageName(n))
	line("source %s", Quote(source))

	b.WriteString("\n")
	line("[headers]")
	for _, f := range m.Fields() {
		line("%s: %s", f.Key(), Quote(f.Display()))
	}

	b.WriteString("\n")
	line("[addresses]")
	for _, name := range addressHeaders {
		for k, a := range m.Addresses(name) {
			line("%s %d display=%s spec=%s", name, k, Quote(a.Display), Quote(a.Spec))
		}
	}

	b.WriteString("\n")
	line("[date]")
	if raw, present, d, valid := m.Date(); !present {
		line("none")
	} else {
		line("raw %s", Quote(raw))
		if !valid {
			line("valid no")
		} else {
			line("valid yes")
			line("utc %s", d.UTC())
			line("offset %s", d.Offset())
			line("epoch %d", d.Epoch)
		}
	}

	b.WriteString("\n")
	line("[structure]")
	for _, p := range m.Parts {
		structureLine(&b, p)
	}

	b.WriteString("\n")
	line("[body]")
	body(&b, "text", m.TextBody)
	body(&b, "html", m.HTMLBody)

	b.WriteString("\n")
	line("[attachments]")
	for _, p := range m.Attachments {
		fn := "-"
		if p.HasFilename {
			fn = Quote(p.Filename)
		}
		line("%d type=%s filename=%s size=%d adler32=%s file=%s",
			p.Index, p.MediaType(), fn, len(p.Content), checksum.Adler32Hex(p.Content), AttachmentPath(n, p.Index))
	}
	return b.String()
}

func structureLine(b *strings.Builder, p *message.Part) {
	b.WriteString(strings.Repeat("  ", p.Depth))
	fmt.Fprintf(b, "%d %s", p.Index, p.MediaType())
	if p.IsText() {
		fmt.Fprintf(b, " charset=%s", p.Charset)
	}
	fmt.Fprintf(b, " cte=%s", p.Encoding)
	if p.HasDisposition {
		fmt.Fprintf(b, " disposition=%s", p.Disposition)
	}
	if p.HasFilename {
		fmt.Fprintf(b, " filename=%s", Quote(p.Filename))
	}
	switch p.Kind {
	case message.Multipart:
		fmt.Fprintf(b, " boundary=%s parts=%d preamble=%d", Quote(p.Boundary), len(p.Children), p.Preamble)
		if p.Epilogue < 0 {
			b.WriteString(" epilogue=none")
		} else {
			fmt.Fprintf(b, " epilogue=%d", p.Epilogue)
		}
	case message.MessageContainer:
		fmt.Fprintf(b, " parts=%d", len(p.Children))
	default:
		fmt.Fprintf(b, " size=%d adler32=%s role=%s", len(p.Content), checksum.Adler32Hex(p.Content), p.Role)
	}
	b.WriteByte('\n')
}

func body(b *strings.Builder, label string, p *message.Part) {
	if p == nil {
		fmt.Fprintf(b, "%s none\n", label)
		return
	}
	text := p.Text()
	fmt.Fprintf(b, "%s %d chars %d\n", label, p.Index, utf8.RuneCountInString(text))
	if text == "" {
		return
	}
	text = strings.TrimSuffix(text, "\n")
	for _, l := range strings.Split(text, "\n") {
		b.WriteString("| ")
		b.WriteString(Escape(l))
		b.WriteByte('\n')
	}
}

// WriteAll parses every source and writes summary.txt, messages/ and parts/
// into outDir (created if missing).
func WriteAll(outDir string, sources []mailbox.Source) error {
	if err := os.MkdirAll(filepath.Join(outDir, "messages"), 0o755); err != nil {
		return err
	}
	var summary strings.Builder
	fmt.Fprintf(&summary, "messages %d\n", len(sources))
	for i, src := range sources {
		n := i + 1
		m := message.Parse(src.Data)
		summary.WriteString(SummaryLine(n, src.ID, m))
		summary.WriteByte('\n')
		name := filepath.Join(outDir, "messages", MessageName(n)+".txt")
		if err := os.WriteFile(name, []byte(Render(n, src.ID, m)), 0o644); err != nil {
			return err
		}
		if len(m.Attachments) == 0 {
			continue
		}
		if err := os.MkdirAll(filepath.Join(outDir, "parts", MessageName(n)), 0o755); err != nil {
			return err
		}
		for _, p := range m.Attachments {
			if err := os.WriteFile(filepath.Join(outDir, AttachmentPath(n, p.Index)), p.Content, 0o644); err != nil {
				return err
			}
		}
	}
	return os.WriteFile(filepath.Join(outDir, "summary.txt"), []byte(summary.String()), 0o644)
}
