// Package header splits a message into its header block and body, unfolds the
// header fields and provides case-insensitive lookup.
package header

import (
	"example.com/mime/charset"
	"example.com/mime/internal/lex"
	"example.com/mime/rfc2047"
)

// Field is one header field: its name and raw (unfolded) value, both decoded
// from UTF-8. The raw value is everything after the first colon, so it
// normally starts with a blank.
type Field struct {
	Name  string
	Value string
}

// Key returns the field name with surrounding blanks stripped and ASCII
// letters lower-cased; it is the name used for lookups and in the dump.
func (f Field) Key() string { return charset.Normalize(f.Name) }

// collapsed lists the fields whose dumped value is whitespace-collapsed raw
// text rather than decoded unstructured text.
var collapsed = map[string]bool{
	"content-disposition": true, "content-id": true,
	"content-transfer-encoding": true, "content-type": true, "date": true,
	"in-reply-to": true, "message-id": true, "mime-version": true,
	"received": true, "references": true, "return-path": true,
}

// Display returns the value of the field as shown in the output dump.
func (f Field) Display() string {
	if collapsed[f.Key()] {
		return lex.Collapse(f.Value)
	}
	return rfc2047.DecodeUnstructured(f.Value)
}

// Collapse replaces each run of SPACE and TAB by one SPACE and strips a
// leading and trailing SPACE.
func Collapse(s string) string { return lex.Collapse(s) }

// Fields is an ordered list of header fields.
type Fields []Field

// Get returns the first field called name (compared case-insensitively; name
// must be lower case).
func (fs Fields) Get(name string) (Field, bool) {
	for _, f := range fs {
		if f.Key() == name {
			return f, true
		}
	}
	return Field{}, false
}

// All returns every field called name, in order.
func (fs Fields) All(name string) []Field {
	var out []Field
	for _, f := range fs {
		if f.Key() == name {
			out = append(out, f)
		}
	}
	return out
}

func isNameByte(c byte) bool { return c >= 0x21 && c <= 0x7E && c != ':' }

// fieldColon returns the index of the colon of a field line, or -1 if line is
// not a field line.
func fieldColon(line []byte) int {
	for i, c := range line {
		if c == ':' {
			if i == 0 {
				return -1
			}
			return i
		}
		if !isNameByte(c) {
			return -1
		}
	}
	return -1
}

// Parse reads the header block at the start of msg, whose lines are
// terminated by LF only. It returns the fields in order and the offset at
// which the body starts.
func Parse(msg []byte) (fields Fields, bodyStart int) {
	pos := 0
	var cur [][]byte // lines of the field being collected
	flush := func() {
		if cur == nil {
			return
		}
		var raw []byte
		if len(cur) == 1 {
			raw = cur[0]
		} else {
			n := 0
			for _, l := range cur {
				n += len(l)
			}
			raw = make([]byte, 0, n)
			for _, l := range cur {
				raw = append(raw, l...)
			}
		}
		colon := fieldColon(cur[0])
		// The first line was already validated; colon is the same in raw.
		fields = append(fields, Field{
			Name:  charset.DecodeUTF8(raw[:colon]),
			Value: charset.DecodeUTF8(raw[colon+1:]),
		})
		cur = nil
	}
	for pos < len(msg) {
		end := pos
		for end < len(msg) && msg[end] != '\n' {
			end++
		}
		line := msg[pos:end]
		next := end
		if end < len(msg) {
			next = end + 1
		}
		if len(line) == 0 {
			flush()
			return fields, next
		}
		if (line[0] == ' ' || line[0] == '\t') && cur != nil {
			cur = append(cur, line)
		} else if fieldColon(line) >= 0 {
			flush()
			cur = [][]byte{line}
		} else {
			flush()
			return fields, pos
		}
		pos = next
	}
	flush()
	return fields, len(msg)
}
