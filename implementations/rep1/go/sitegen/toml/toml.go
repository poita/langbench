// Package toml parses the small TOML subset used by sitegen for site
// configuration and for the front matter of content files.
//
// The subset has no tables, dotted keys or multi-line values. A document is a
// sequence of lines; each line is blank, a comment, or an assignment
//
//	key = value   # optional comment
//
// where value is a basic string, an integer, a boolean or a single-line array
// of strings.
package toml

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Kind identifies the type of a Value.
type Kind uint8

// The kinds of value in the TOML subset.
const (
	String Kind = iota
	Integer
	Boolean
	Array // an array of strings
)

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

// A Value is one parsed right-hand side. Exactly one of the fields Str, Int,
// Bool and Strings is meaningful, as selected by Kind.
type Value struct {
	Kind    Kind
	Str     string
	Int     int64
	Bool    bool
	Strings []string
}

// An Entry is a key and its value.
type Entry struct {
	Key   string
	Value Value
}

// A Document is a parsed TOML-subset document. Entries are kept in the order
// in which they appear in the source.
type Document struct {
	entries []Entry
	index   map[string]int
}

// Entries returns the assignments in source order. The slice must not be
// modified.
func (d *Document) Entries() []Entry { return d.entries }

// Get returns the value of key.
func (d *Document) Get(key string) (Value, bool) {
	i, ok := d.index[key]
	if !ok {
		return Value{}, false
	}
	return d.entries[i].Value, true
}

// String returns the string value of key. ok is false if the key is absent or
// not a string.
func (d *Document) String(key string) (s string, ok bool) {
	v, found := d.Get(key)
	if !found || v.Kind != String {
		return "", false
	}
	return v.Str, true
}

// Int returns the integer value of key. ok is false if the key is absent or
// not an integer.
func (d *Document) Int(key string) (n int64, ok bool) {
	v, found := d.Get(key)
	if !found || v.Kind != Integer {
		return 0, false
	}
	return v.Int, true
}

// Bool returns the boolean value of key. ok is false if the key is absent or
// not a boolean.
func (d *Document) Bool(key string) (b bool, ok bool) {
	v, found := d.Get(key)
	if !found || v.Kind != Boolean {
		return false, false
	}
	return v.Bool, true
}

// Strings returns the array value of key. ok is false if the key is absent or
// not an array.
func (d *Document) Strings(key string) (a []string, ok bool) {
	v, found := d.Get(key)
	if !found || v.Kind != Array {
		return nil, false
	}
	return v.Strings, true
}

// A SyntaxError reports a malformed line.
type SyntaxError struct {
	Line int // 1-based line number
	Msg  string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("toml: line %d: %s", e.Line, e.Msg)
}

// Parse parses a document. Lines are separated by LF; a trailing CR on a line
// is tolerated and ignored.
func Parse(src string) (*Document, error) {
	d := &Document{index: make(map[string]int)}
	line := 0
	for len(src) > 0 {
		var text string
		if i := strings.IndexByte(src, '\n'); i >= 0 {
			text, src = src[:i], src[i+1:]
		} else {
			text, src = src, ""
		}
		line++
		text = strings.TrimSuffix(text, "\r")
		e, ok, err := parseLine(text)
		if err != nil {
			return nil, &SyntaxError{Line: line, Msg: err.Error()}
		}
		if !ok {
			continue
		}
		if _, dup := d.index[e.Key]; dup {
			return nil, &SyntaxError{Line: line, Msg: "duplicate key " + strconv.Quote(e.Key)}
		}
		d.index[e.Key] = len(d.entries)
		d.entries = append(d.entries, e)
	}
	return d, nil
}

func isBlank(c byte) bool { return c == ' ' || c == '\t' }

func isKeyByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}

func skipBlank(s string, i int) int {
	for i < len(s) && isBlank(s[i]) {
		i++
	}
	return i
}

// parseLine parses one line. ok is false for blank and comment lines.
func parseLine(s string) (e Entry, ok bool, err error) {
	i := skipBlank(s, 0)
	if i == len(s) || s[i] == '#' {
		return e, false, nil
	}
	start := i
	for i < len(s) && isKeyByte(s[i]) {
		i++
	}
	if i == start {
		return e, false, fmt.Errorf("expected a key")
	}
	key := s[start:i]
	i = skipBlank(s, i)
	if i >= len(s) || s[i] != '=' {
		return e, false, fmt.Errorf("expected '=' after key %q", key)
	}
	i = skipBlank(s, i+1)
	v, i, err := parseValue(s, i)
	if err != nil {
		return e, false, err
	}
	i = skipBlank(s, i)
	if i < len(s) && s[i] != '#' {
		return e, false, fmt.Errorf("unexpected text after value")
	}
	return Entry{Key: key, Value: v}, true, nil
}

func parseValue(s string, i int) (Value, int, error) {
	if i >= len(s) {
		return Value{}, i, fmt.Errorf("missing value")
	}
	switch c := s[i]; {
	case c == '"':
		str, j, err := parseString(s, i)
		return Value{Kind: String, Str: str}, j, err
	case c == '[':
		return parseArray(s, i)
	case c == '-' || c >= '0' && c <= '9':
		j := i
		if s[j] == '-' {
			j++
		}
		k := j
		for k < len(s) && s[k] >= '0' && s[k] <= '9' {
			k++
		}
		if k == j || (s[j] == '0' && k-j > 1) {
			return Value{}, i, fmt.Errorf("malformed integer")
		}
		n, err := strconv.ParseInt(s[i:k], 10, 64)
		if err != nil {
			return Value{}, i, fmt.Errorf("integer out of range")
		}
		return Value{Kind: Integer, Int: n}, k, nil
	case strings.HasPrefix(s[i:], "true"):
		return Value{Kind: Boolean, Bool: true}, i + 4, nil
	case strings.HasPrefix(s[i:], "false"):
		return Value{Kind: Boolean, Bool: false}, i + 5, nil
	}
	return Value{}, i, fmt.Errorf("unrecognised value")
}

// parseString parses a basic string whose opening quote is at s[i].
func parseString(s string, i int) (string, int, error) {
	i++ // opening quote
	// Fast path: no escapes.
	j := i
	for j < len(s) && s[j] != '"' && s[j] != '\\' {
		j++
	}
	if j < len(s) && s[j] == '"' {
		return s[i:j], j + 1, nil
	}
	var b strings.Builder
	b.WriteString(s[i:j])
	i = j
	for i < len(s) {
		c := s[i]
		switch c {
		case '"':
			return b.String(), i + 1, nil
		case '\\':
			if i+1 >= len(s) {
				return "", i, fmt.Errorf("unterminated string")
			}
			switch s[i+1] {
			case '"':
				b.WriteByte('"')
			case '\\':
				b.WriteByte('\\')
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			case 'r':
				b.WriteByte('\r')
			case 'u':
				if i+6 > len(s) {
					return "", i, fmt.Errorf("short \\u escape")
				}
				n, err := strconv.ParseUint(s[i+2:i+6], 16, 32)
				if err != nil {
					return "", i, fmt.Errorf("bad \\u escape")
				}
				r := rune(n)
				if !utf8.ValidRune(r) {
					r = utf8.RuneError
				}
				b.WriteRune(r)
				i += 4
			default:
				return "", i, fmt.Errorf("unknown escape \\%c", s[i+1])
			}
			i += 2
		default:
			b.WriteByte(c)
			i++
		}
	}
	return "", i, fmt.Errorf("unterminated string")
}

func parseArray(s string, i int) (Value, int, error) {
	i++ // '['
	v := Value{Kind: Array, Strings: []string{}}
	i = skipBlank(s, i)
	for {
		if i >= len(s) {
			return Value{}, i, fmt.Errorf("unterminated array")
		}
		if s[i] == ']' {
			return v, i + 1, nil
		}
		if s[i] != '"' {
			return Value{}, i, fmt.Errorf("arrays may only contain strings")
		}
		str, j, err := parseString(s, i)
		if err != nil {
			return Value{}, i, err
		}
		v.Strings = append(v.Strings, str)
		i = skipBlank(s, j)
		if i < len(s) && s[i] == ',' {
			i = skipBlank(s, i+1)
			continue
		}
		if i < len(s) && s[i] == ']' {
			return v, i + 1, nil
		}
		return Value{}, i, fmt.Errorf("expected ',' or ']' in array")
	}
}
