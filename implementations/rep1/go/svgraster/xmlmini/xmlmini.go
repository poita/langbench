// Package xmlmini is a tiny non-validating XML reader that understands just
// enough XML for SVG documents: elements and attributes. Text is ignored,
// namespace prefixes are stripped and the five predefined entities plus
// numeric character references are decoded in attribute values.
package xmlmini

import (
	"errors"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Attr is one attribute with its (prefix-stripped) name and decoded value.
type Attr struct{ Name, Value string }

// Element is a node of the parsed tree.
type Element struct {
	Tag      string // prefix-stripped element name
	Attrs    []Attr // in document order, one entry per distinct name
	Children []*Element
}

// Attr returns the value of the named attribute.
func (e *Element) Attr(name string) (string, bool) {
	for i := range e.Attrs {
		if e.Attrs[i].Name == name {
			return e.Attrs[i].Value, true
		}
	}
	return "", false
}

// ErrNoRoot is returned when the input has no start tag.
var ErrNoRoot = errors.New("xmlmini: no document element")

// Parse reads data in one forward pass and returns the document element: the
// first start tag in the input.
func Parse(data []byte) (*Element, error) {
	s := string(data)
	var root *Element
	var stack []*Element
	i := 0
	for i < len(s) {
		lt := strings.IndexByte(s[i:], '<')
		if lt < 0 {
			break
		}
		i += lt
		rest := s[i:]
		switch {
		case strings.HasPrefix(rest, "<?"):
			j := strings.Index(rest, "?>")
			if j < 0 {
				return nil, errors.New("xmlmini: unterminated processing instruction")
			}
			i += j + 2
		case strings.HasPrefix(rest, "<!--"):
			j := strings.Index(rest[4:], "-->")
			if j < 0 {
				return nil, errors.New("xmlmini: unterminated comment")
			}
			i += 4 + j + 3
		case strings.HasPrefix(rest, "<![CDATA["):
			j := strings.Index(rest, "]]>")
			if j < 0 {
				return nil, errors.New("xmlmini: unterminated CDATA section")
			}
			i += j + 3
		case strings.HasPrefix(rest, "<!"):
			end, ok := skipDecl(rest)
			if !ok {
				return nil, errors.New("xmlmini: unterminated declaration")
			}
			i += end
		case strings.HasPrefix(rest, "</"):
			j := strings.IndexByte(rest, '>')
			if j < 0 {
				return nil, errors.New("xmlmini: unterminated end tag")
			}
			i += j + 1
			if len(stack) > 0 {
				stack = stack[:len(stack)-1]
				if len(stack) == 0 {
					return root, nil
				}
			}
		default:
			el, n, selfClose, err := parseStartTag(rest)
			if err != nil {
				return nil, err
			}
			i += n
			if root == nil {
				root = el
			} else if len(stack) > 0 {
				p := stack[len(stack)-1]
				p.Children = append(p.Children, el)
			} else {
				return root, nil
			}
			if !selfClose {
				stack = append(stack, el)
			} else if len(stack) == 0 {
				return root, nil
			}
		}
	}
	if root == nil {
		return nil, ErrNoRoot
	}
	return root, nil
}

// skipDecl skips a <!...> declaration, including a DOCTYPE internal subset
// and quoted strings. It returns the number of bytes consumed.
func skipDecl(s string) (int, bool) {
	depth := 0
	for i := 2; i < len(s); i++ {
		switch c := s[i]; c {
		case '"', '\'':
			j := strings.IndexByte(s[i+1:], c)
			if j < 0 {
				return 0, false
			}
			i += j + 1
		case '[':
			depth++
		case ']':
			depth--
		case '>':
			if depth <= 0 {
				return i + 1, true
			}
		}
	}
	return 0, false
}

func isSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }

// strip removes a namespace prefix.
func strip(name string) string {
	if i := strings.LastIndexByte(name, ':'); i >= 0 {
		return name[i+1:]
	}
	return name
}

// parseStartTag parses "<name attrs>" or "<name attrs/>" at the start of s.
func parseStartTag(s string) (el *Element, n int, selfClose bool, err error) {
	i := 1
	for i < len(s) && !isSpace(s[i]) && s[i] != '>' && s[i] != '/' {
		i++
	}
	el = &Element{Tag: strip(s[1:i])}
	for {
		for i < len(s) && isSpace(s[i]) {
			i++
		}
		if i >= len(s) {
			return nil, 0, false, errors.New("xmlmini: unterminated start tag")
		}
		switch s[i] {
		case '>':
			return el, i + 1, false, nil
		case '/':
			if i+1 < len(s) && s[i+1] == '>' {
				return el, i + 2, true, nil
			}
			i++
			continue
		}
		ns := i
		for i < len(s) && !isSpace(s[i]) && s[i] != '=' && s[i] != '>' && s[i] != '/' {
			i++
		}
		name := strip(s[ns:i])
		for i < len(s) && isSpace(s[i]) {
			i++
		}
		value := ""
		if i < len(s) && s[i] == '=' {
			i++
			for i < len(s) && isSpace(s[i]) {
				i++
			}
			if i < len(s) && (s[i] == '"' || s[i] == '\'') {
				q := s[i]
				j := strings.IndexByte(s[i+1:], q)
				if j < 0 {
					return nil, 0, false, errors.New("xmlmini: unterminated attribute value")
				}
				value = s[i+1 : i+1+j]
				i += j + 2
			} else {
				vs := i
				for i < len(s) && !isSpace(s[i]) && s[i] != '>' {
					i++
				}
				value = s[vs:i]
			}
			if strings.IndexByte(value, '&') >= 0 {
				value = unescape(value)
			}
		}
		if name == "" {
			continue
		}
		set := false
		for k := range el.Attrs {
			if el.Attrs[k].Name == name {
				el.Attrs[k].Value = value
				set = true
				break
			}
		}
		if !set {
			el.Attrs = append(el.Attrs, Attr{name, value})
		}
	}
}

// unescape decodes the predefined entities and numeric character references.
// Any other &...; sequence is kept verbatim.
func unescape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); {
		if s[i] != '&' {
			b.WriteByte(s[i])
			i++
			continue
		}
		semi := strings.IndexByte(s[i:], ';')
		if semi < 0 {
			b.WriteString(s[i:])
			break
		}
		ent := s[i+1 : i+semi]
		if r, ok := decodeEntity(ent); ok {
			b.WriteRune(r)
		} else {
			b.WriteString(s[i : i+semi+1])
		}
		i += semi + 1
	}
	return b.String()
}

func decodeEntity(ent string) (rune, bool) {
	switch ent {
	case "amp":
		return '&', true
	case "lt":
		return '<', true
	case "gt":
		return '>', true
	case "quot":
		return '"', true
	case "apos":
		return '\'', true
	}
	if len(ent) < 2 || ent[0] != '#' {
		return 0, false
	}
	var v uint64
	var err error
	if ent[1] == 'x' || ent[1] == 'X' {
		v, err = strconv.ParseUint(ent[2:], 16, 32)
	} else {
		v, err = strconv.ParseUint(ent[1:], 10, 32)
	}
	if err != nil || v == 0 || !utf8.ValidRune(rune(v)) {
		return 0, false
	}
	return rune(v), true
}
