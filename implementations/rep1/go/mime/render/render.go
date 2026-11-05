// Package render formats a parsed message as the normalised text dump and
// produces the matching summary line.
package render

import (
	"strconv"

	"mimedump/address"
	"mimedump/date"
	"mimedump/header"
	"mimedump/message"
)

const hexDigits = "0123456789abcdef"

// AppendEsc appends esc(s): backslash, LF, CR, TAB and '"' are backslash
// escaped, other control characters, DEL and U+0080-U+009F become \xHH, and
// everything else is copied. s must be valid UTF-8.
func AppendEsc(dst []byte, s string) []byte {
	start := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		var rep string
		n := 1
		switch {
		case c == '\\':
			rep = `\\`
		case c == '\n':
			rep = `\n`
		case c == '\r':
			rep = `\r`
		case c == '\t':
			rep = `\t`
		case c == '"':
			rep = `\"`
		case c < 0x20 || c == 0x7F:
			rep = `\x` + string([]byte{hexDigits[c>>4], hexDigits[c&15]})
		case c == 0xC2 && i+1 < len(s) && s[i+1] >= 0x80 && s[i+1] <= 0x9F:
			d := s[i+1]
			rep = `\x` + string([]byte{hexDigits[d>>4], hexDigits[d&15]})
			n = 2
		default:
			continue
		}
		dst = append(dst, s[start:i]...)
		dst = append(dst, rep...)
		i += n - 1
		start = i + 1
	}
	return append(dst, s[start:]...)
}

// AppendQuoted appends q(s) = '"' + esc(s) + '"'.
func AppendQuoted(dst []byte, s string) []byte {
	dst = append(dst, '"')
	dst = AppendEsc(dst, s)
	return append(dst, '"')
}

// Esc returns esc(s).
func Esc(s string) string { return string(AppendEsc(nil, s)) }

// Quote returns q(s).
func Quote(s string) string { return string(AppendQuoted(nil, s)) }

func hex8(n uint32) string {
	var b [8]byte
	for i := 7; i >= 0; i-- {
		b[i] = hexDigits[n&15]
		n >>= 4
	}
	return string(b[:])
}

func pad(n, width int) string {
	s := strconv.Itoa(n)
	for len(s) < width {
		s = "0" + s
	}
	return s
}

// Number formats a message number as four digits.
func Number(n int) string { return pad(n, 4) }

// AttachmentPath is the output-relative path of an attachment's bytes.
func AttachmentPath(msgNum, partIndex int) string {
	return "parts/" + Number(msgNum) + "/" + pad(partIndex, 3) + ".bin"
}

// SummaryLine is the summary.txt line for message number num (1-based).
func SummaryLine(num int, sourceID string, rawLen int, m *message.Message) string {
	idx := func(p *message.Part) string {
		if p == nil {
			return "-"
		}
		return strconv.Itoa(p.Index)
	}
	return Number(num) + " source=" + Quote(sourceID) + " bytes=" + strconv.Itoa(rawLen) +
		" parts=" + strconv.Itoa(len(m.Parts)) + " attachments=" + strconv.Itoa(len(m.Attachments)) +
		" text=" + idx(m.Text) + " html=" + idx(m.HTML)
}

// Message renders the dump of message number num (1-based).
func Message(num int, sourceID string, m *message.Message) []byte {
	var b []byte
	root := m.Parts[0]
	line := func(parts ...string) {
		for _, p := range parts {
			b = append(b, p...)
		}
		b = append(b, '\n')
	}

	line("[message]")
	line("id ", Number(num))
	line("source ", Quote(sourceID))
	line()

	line("[headers]")
	for _, f := range root.Headers {
		b = append(b, f.Name...)
		b = append(b, ": "...)
		b = AppendQuoted(b, f.DisplayValue())
		b = append(b, '\n')
	}
	line()

	line("[addresses]")
	for _, name := range []string{"from", "sender", "reply-to", "to", "cc", "bcc"} {
		k := 0
		for _, f := range root.Headers {
			if f.Name != name {
				continue
			}
			for _, a := range address.ParseList(f.Raw) {
				line(name, " ", strconv.Itoa(k), " display=", Quote(a.Display), " spec=", Quote(a.Spec))
				k++
			}
		}
	}
	line()

	line("[date]")
	if f, ok := header.Find(root.Headers, "date"); !ok {
		line("none")
	} else {
		line("raw ", Quote(f.Raw))
		if d, ok := date.Parse(f.Raw); !ok {
			line("valid no")
		} else {
			line("valid yes")
			line("utc ", d.UTC())
			line("offset ", d.Offset())
			line("epoch ", strconv.FormatInt(d.Epoch, 10))
		}
	}
	line()

	line("[structure]")
	for _, p := range m.Parts {
		for i := 0; i < p.Depth; i++ {
			b = append(b, "  "...)
		}
		b = append(b, strconv.Itoa(p.Index)...)
		b = append(b, ' ')
		b = append(b, p.Type...)
		b = append(b, '/')
		b = append(b, p.Subtype...)
		if p.IsText() {
			b = append(b, " charset="...)
			b = append(b, p.Charset...)
		}
		b = append(b, " cte="...)
		b = append(b, p.Encoding...)
		if p.HasDisposition {
			b = append(b, " disposition="...)
			b = append(b, p.Disposition...)
		}
		if p.HasFilename {
			b = append(b, " filename="...)
			b = AppendQuoted(b, p.Filename)
		}
		switch p.Kind {
		case message.Multipart:
			b = append(b, " boundary="...)
			b = AppendQuoted(b, p.Boundary)
			b = append(b, " parts="...)
			b = strconv.AppendInt(b, int64(len(p.Children)), 10)
			b = append(b, " preamble="...)
			b = strconv.AppendInt(b, int64(p.Preamble), 10)
			b = append(b, " epilogue="...)
			if p.Epilogue < 0 {
				b = append(b, "none"...)
			} else {
				b = strconv.AppendInt(b, int64(p.Epilogue), 10)
			}
		case message.MessageEnv:
			b = append(b, " parts="...)
			b = strconv.AppendInt(b, int64(len(p.Children)), 10)
		default:
			b = append(b, " size="...)
			b = strconv.AppendInt(b, int64(len(p.Content)), 10)
			b = append(b, " adler32="...)
			b = append(b, hex8(p.Adler32)...)
			b = append(b, " role="...)
			b = append(b, p.Role.String()...)
		}
		b = append(b, '\n')
	}
	line()

	line("[body]")
	b = appendBody(b, "text", m.Text)
	b = appendBody(b, "html", m.HTML)
	line()

	line("[attachments]")
	for _, p := range m.Attachments {
		name := "-"
		if p.HasFilename {
			name = Quote(p.Filename)
		}
		line(strconv.Itoa(p.Index), " type=", p.Type, "/", p.Subtype, " filename=", name,
			" size=", strconv.Itoa(len(p.Content)), " adler32=", hex8(p.Adler32),
			" file=", AttachmentPath(num, p.Index))
	}
	return b
}

func appendBody(b []byte, label string, p *message.Part) []byte {
	if p == nil {
		return append(b, label+" none\n"...)
	}
	b = append(b, label...)
	b = append(b, ' ')
	b = strconv.AppendInt(b, int64(p.Index), 10)
	b = append(b, " chars "...)
	b = strconv.AppendInt(b, int64(p.Chars), 10)
	b = append(b, '\n')
	text := p.Text
	for len(text) > 0 {
		end := len(text)
		next := end
		for i := 0; i < len(text); i++ {
			if text[i] == '\n' {
				end, next = i, i+1
				break
			}
		}
		b = append(b, "| "...)
		b = AppendEsc(b, text[:end])
		b = append(b, '\n')
		text = text[next:]
	}
	return b
}
