// Package toml implements the small TOML subset used by sitegen for
// site.toml and for the front matter of content files.
//
// A document is a sequence of lines. Each line is blank, a comment (first
// non-blank character is '#'), or an assignment "key = value". Values are
// basic strings, integers, booleans or single-line arrays of basic strings.
// There are no tables, dotted keys or multi-line values.
//
// Use Parse to read a document:
//
//	doc, err := toml.Parse("title = \"Hi\"\nn = 3\n")
//	title, _ := doc.String("title")
package toml

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Kind identifies the type of a Value.
type Kind int

// The value kinds of the TOML subset.
const (
	String Kind = iota
	Integer
	Boolean
	Array
)

// String returns the lower-case name of the kind.
func (k Kind) String() string {
	switch k {
	case String:
		return "string"
	case Integer:
		return "integer"
	case Boolean:
		return "boolean"
	case Array:
		return "array"
	}
	return "unknown"
}

// Value is one parsed TOML value. Only the field matching Kind is meaningful.
type Value struct {
	Kind  Kind
	Str   string   // Kind == String
	Int   int64    // Kind == Integer
	Bool  bool     // Kind == Boolean
	Array []string // Kind == Array
}

// Entry is a key with its value.
type Entry struct {
	Key   string
	Value Value
}

// Document is a parsed document: its entries in file order.
type Document struct {
	Entries []Entry
}

// Lookup returns the value stored under key.
func (d *Document) Lookup(key string) (Value, bool) {
	for i := range d.Entries {
		if d.Entries[i].Key == key {
			return d.Entries[i].Value, true
		}
	}
	return Value{}, false
}

// String returns the string stored under key; ok is false when the key is
// missing or is not a string.
func (d *Document) String(key string) (s string, ok bool) {
	v, found := d.Lookup(key)
	if !found || v.Kind != String {
		return "", false
	}
	return v.Str, true
}

// Int returns the integer stored under key.
func (d *Document) Int(key string) (n int64, ok bool) {
	v, found := d.Lookup(key)
	if !found || v.Kind != Integer {
		return 0, false
	}
	return v.Int, true
}

// Bool returns the boolean stored under key.
func (d *Document) Bool(key string) (b bool, ok bool) {
	v, found := d.Lookup(key)
	if !found || v.Kind != Boolean {
		return false, false
	}
	return v.Bool, true
}

// Strings returns the string array stored under key.
func (d *Document) Strings(key string) (a []string, ok bool) {
	v, found := d.Lookup(key)
	if !found || v.Kind != Array {
		return nil, false
	}
	return v.Array, true
}

// SyntaxError describes a malformed line.
type SyntaxError struct {
	Line int // 1-based line number
	Msg  string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("toml: line %d: %s", e.Line, e.Msg)
}

// Parse parses a document in the TOML subset. Lines are separated by LF.
func Parse(src string) (*Document, error) {
	doc := &Document{}
	seen := map[string]bool{}
	lineNo := 0
	for len(src) > 0 || lineNo == 0 {
		lineNo++
		var line string
		if i := strings.IndexByte(src, '\n'); i >= 0 {
			line, src = src[:i], src[i+1:]
		} else {
			line, src = src, ""
		}
		entry, ok, err := parseLine(line)
		if err != nil {
			return nil, &SyntaxError{Line: lineNo, Msg: err.Error()}
		}
		if !ok {
			continue
		}
		if seen[entry.Key] {
			return nil, &SyntaxError{Line: lineNo, Msg: "duplicate key " + strconv.Quote(entry.Key)}
		}
		seen[entry.Key] = true
		doc.Entries = append(doc.Entries, entry)
	}
	return doc, nil
}

func isBlank(c byte) bool { return c == ' ' || c == '\t' }

func isKeyChar(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}

func skipBlanks(s string, i int) int {
	for i < len(s) && isBlank(s[i]) {
		i++
	}
	return i
}

// parseLine parses one line; ok is false for blank and comment lines.
func parseLine(line string) (e Entry, ok bool, err error) {
	i := skipBlanks(line, 0)
	if i == len(line) || line[i] == '#' {
		return e, false, nil
	}
	start := i
	for i < len(line) && isKeyChar(line[i]) {
		i++
	}
	if i == start {
		return e, false, fmt.Errorf("expected a key")
	}
	e.Key = line[start:i]
	i = skipBlanks(line, i)
	if i >= len(line) || line[i] != '=' {
		return e, false, fmt.Errorf("expected '=' after key")
	}
	i = skipBlanks(line, i+1)
	if i >= len(line) {
		return e, false, fmt.Errorf("missing value")
	}
	v, i, err := parseValue(line, i)
	if err != nil {
		return e, false, err
	}
	i = skipBlanks(line, i)
	if i < len(line) && line[i] != '#' {
		return e, false, fmt.Errorf("unexpected text after value")
	}
	e.Value = v
	return e, true, nil
}

func parseValue(s string, i int) (Value, int, error) {
	switch c := s[i]; {
	case c == '"':
		str, j, err := parseString(s, i)
		return Value{Kind: String, Str: str}, j, err
	case c == '[':
		return parseArray(s, i)
	case c == '-' || c >= '0' && c <= '9':
		return parseInt(s, i)
	case strings.HasPrefix(s[i:], "true"):
		return Value{Kind: Boolean, Bool: true}, i + 4, nil
	case strings.HasPrefix(s[i:], "false"):
		return Value{Kind: Boolean}, i + 5, nil
	}
	return Value{}, i, fmt.Errorf("invalid value")
}

func parseInt(s string, i int) (Value, int, error) {
	j := i
	if s[j] == '-' {
		j++
	}
	k := j
	for k < len(s) && s[k] >= '0' && s[k] <= '9' {
		k++
	}
	if k == j {
		return Value{}, i, fmt.Errorf("invalid integer")
	}
	if s[j] == '0' && k-j > 1 {
		return Value{}, i, fmt.Errorf("leading zeros are not allowed")
	}
	n, err := strconv.ParseInt(s[i:k], 10, 64)
	if err != nil {
		return Value{}, i, fmt.Errorf("integer out of range")
	}
	return Value{Kind: Integer, Int: n}, k, nil
}

// parseString parses a basic string starting at the opening quote s[i].
func parseString(s string, i int) (string, int, error) {
	i++ // opening quote
	var sb strings.Builder
	for i < len(s) {
		c := s[i]
		switch c {
		case '"':
			return sb.String(), i + 1, nil
		case '\\':
			if i+1 >= len(s) {
				return "", i, fmt.Errorf("unterminated escape")
			}
			switch s[i+1] {
			case '"':
				sb.WriteByte('"')
			case '\\':
				sb.WriteByte('\\')
			case 'n':
				sb.WriteByte('\n')
			case 't':
				sb.WriteByte('\t')
			case 'r':
				sb.WriteByte('\r')
			case 'u':
				if i+6 > len(s) {
					return "", i, fmt.Errorf("short \\u escape")
				}
				n, err := strconv.ParseUint(s[i+2:i+6], 16, 32)
				if err != nil || strings.ContainsAny(s[i+2:i+6], "+-_") {
					return "", i, fmt.Errorf("invalid \\u escape")
				}
				if !utf8.ValidRune(rune(n)) {
					return "", i, fmt.Errorf("\\u escape is not a scalar value")
				}
				sb.WriteRune(rune(n))
				i += 4
			default:
				return "", i, fmt.Errorf("invalid escape \\%c", s[i+1])
			}
			i += 2
		default:
			sb.WriteByte(c)
			i++
		}
	}
	return "", i, fmt.Errorf("unterminated string")
}

func parseArray(s string, i int) (Value, int, error) {
	i = skipBlanks(s, i+1)
	items := []string{}
	for {
		if i >= len(s) {
			return Value{}, i, fmt.Errorf("unterminated array")
		}
		if s[i] == ']' {
			return Value{Kind: Array, Array: items}, i + 1, nil
		}
		if s[i] != '"' {
			return Value{}, i, fmt.Errorf("arrays may only contain strings")
		}
		str, j, err := parseString(s, i)
		if err != nil {
			return Value{}, i, err
		}
		items = append(items, str)
		i = skipBlanks(s, j)
		if i < len(s) && s[i] == ',' {
			i = skipBlanks(s, i+1)
		} else if i >= len(s) || s[i] != ']' {
			return Value{}, i, fmt.Errorf("expected ',' or ']' in array")
		}
	}
}
