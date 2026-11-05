// Package header splits a message into its header fields and body.
package header

import (
	"bytes"
	"strings"

	"mimedump/charset"
	"mimedump/internal/scan"
	"mimedump/lines"
	"mimedump/rfc2047"
)

// Field is one header field.
type Field struct {
	// Name is the field name stripped of spaces and tabs and lower-cased.
	Name string
	// Raw is everything after the first ':' of the unfolded field, decoded
	// from UTF-8. Leading whitespace is kept.
	Raw string
}

// Parse reads the header block at the start of msg, which must already have
// LF line endings (see lines.NormalizeCRLF). It returns the fields in order
// and the offset at which the body starts.
//
// An empty line ends the block (the body follows it). A line starting with
// SPACE or TAB after a field continues that field. Any other line must be a
// field line (a non-empty run of printable ASCII other than ':' and then
// ':'); if it is not, the block ends before it and that line starts the body.
func Parse(msg []byte) (fields []Field, bodyStart int) {
	var cur []byte  // unfolded bytes of the field being built
	var shared bool // cur still aliases msg
	flush := func() {
		if cur == nil {
			return
		}
		colon := bytes.IndexByte(cur, ':')
		name := scan.LowerASCII(scan.Trim(string(cur[:colon])))
		fields = append(fields, Field{Name: name, Raw: charset.DecodeUTF8(cur[colon+1:])})
		cur = nil
	}
	pos := 0
	for {
		line, size, ok := lines.Next(msg[pos:])
		if !ok {
			flush()
			return fields, len(msg)
		}
		if len(line) == 0 {
			flush()
			return fields, pos + size
		}
		if scan.IsBlank(line[0]) && cur != nil {
			if shared {
				cur = append(cur[:len(cur):len(cur)], line...)
				shared = false
			} else {
				cur = append(cur, line...)
			}
			pos += size
			continue
		}
		if !isFieldLine(line) {
			flush()
			return fields, pos
		}
		flush()
		cur, shared = line, true
		pos += size
	}
}

func isFieldLine(line []byte) bool {
	for i, c := range line {
		if c == ':' {
			return i > 0
		}
		if c < 0x21 || c > 0x7E {
			return false
		}
	}
	return false
}

// Find returns the first field called name (which must be lower-case).
func Find(fields []Field, name string) (Field, bool) {
	for _, f := range fields {
		if f.Name == name {
			return f, true
		}
	}
	return Field{}, false
}

// Collapse replaces each maximal run of SPACE and TAB with one SPACE and then
// strips a leading and trailing SPACE.
func Collapse(s string) string {
	var sb strings.Builder
	sb.Grow(len(s))
	for i := 0; i < len(s); {
		if !scan.IsBlank(s[i]) {
			sb.WriteByte(s[i])
			i++
			continue
		}
		for i < len(s) && scan.IsBlank(s[i]) {
			i++
		}
		sb.WriteByte(' ')
	}
	return strings.Trim(sb.String(), " ")
}

// verbatim lists the fields whose dumped value is only whitespace-collapsed
// rather than RFC 2047 decoded.
var verbatim = map[string]bool{
	"content-disposition":       true,
	"content-id":                true,
	"content-transfer-encoding": true,
	"content-type":              true,
	"date":                      true,
	"in-reply-to":               true,
	"message-id":                true,
	"mime-version":              true,
	"received":                  true,
	"references":                true,
	"return-path":               true,
}

// DisplayValue is the value of f as shown in the dump's [headers] section.
func (f Field) DisplayValue() string {
	if verbatim[f.Name] {
		return Collapse(f.Raw)
	}
	return rfc2047.DecodeUnstructured(f.Raw)
}
