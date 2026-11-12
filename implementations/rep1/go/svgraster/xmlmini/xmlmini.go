// Package xmlmini is a tiny, forgiving, non-validating XML reader that
// understands just enough XML for SVG documents: elements and attributes.
//
// Processing instructions, comments, DOCTYPE declarations and CDATA sections
// are skipped, character data is ignored, and namespace prefixes are stripped
// from element and attribute names.
package xmlmini

import (
	"errors"
	"strconv"
	"strings"
)

// Node is an element in the parsed tree.
type Node struct {
	// Tag is the element name with any namespace prefix removed.
	Tag string
	// Attrs maps attribute names (prefix removed) to decoded values.
	Attrs    map[string]string
	Children []*Node
}

// Attr returns the value of the named attribute and whether it is present.
func (n *Node) Attr(name string) (string, bool) {
	v, ok := n.Attrs[name]
	return v, ok
}

// ErrNoRoot is returned when the input contains no element.
var ErrNoRoot = errors.New("xmlmini: no document element")

// Parse reads an XML document and returns its root element. Malformed input
// is handled leniently: unclosed elements are closed at end of input and stray
// end tags are ignored. ErrNoRoot is returned if there is no element at all.
func Parse(src []byte) (*Node, error) {
	s := string(src)
	var root *Node
	var stack []*Node
	i := 0
	for i < len(s) {
		lt := strings.IndexByte(s[i:], '<')
		if lt < 0 {
			break
		}
		i += lt
		rest := s[i:]
		switch {
		case strings.HasPrefix(rest, "<!--"):
			i = skipPast(s, i+4, "-->")
		case strings.HasPrefix(rest, "<![CDATA["):
			i = skipPast(s, i+9, "]]>")
		case strings.HasPrefix(rest, "<?"):
			i = skipPast(s, i+2, "?>")
		case strings.HasPrefix(rest, "<!"):
			i = skipDeclaration(s, i+2)
		case strings.HasPrefix(rest, "</"):
			i = skipPast(s, i+2, ">")
			if len(stack) > 0 {
				stack = stack[:len(stack)-1]
			}
		default:
			node, selfClose, next := parseStartTag(s, i+1)
			i = next
			if node == nil {
				continue
			}
			if root == nil {
				root = node
			}
			if len(stack) > 0 {
				p := stack[len(stack)-1]
				p.Children = append(p.Children, node)
			}
			if !selfClose {
				stack = append(stack, node)
			}
		}
	}
	if root == nil {
		return nil, ErrNoRoot
	}
	return root, nil
}

// skipPast returns the index just after the first occurrence of end at or
// after from, or len(s) if there is none.
func skipPast(s string, from int, end string) int {
	if from > len(s) {
		return len(s)
	}
	k := strings.Index(s[from:], end)
	if k < 0 {
		return len(s)
	}
	return from + k + len(end)
}

// skipDeclaration skips a <!DOCTYPE ...> declaration, including an internal
// [...] subset and quoted strings, returning the index after its closing '>'.
func skipDeclaration(s string, i int) int {
	depth := 0
	for i < len(s) {
		switch c := s[i]; c {
		case '"', '\'':
			k := strings.IndexByte(s[i+1:], c)
			if k < 0 {
				return len(s)
			}
			i += k + 1
		case '[':
			depth++
		case ']':
			if depth > 0 {
				depth--
			}
		case '>':
			if depth == 0 {
				return i + 1
			}
		}
		i++
	}
	return len(s)
}

func isSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

func isNameEnd(c byte) bool { return isSpace(c) || c == '=' || c == '/' || c == '>' }

// stripPrefix removes a namespace prefix ("xlink:href" -> "href").
func stripPrefix(name string) string {
	if k := strings.LastIndexByte(name, ':'); k >= 0 {
		return name[k+1:]
	}
	return name
}

// parseStartTag parses the tag whose name begins at s[i]. It returns the
// node, whether the tag was self-closing, and the index after the tag.
func parseStartTag(s string, i int) (*Node, bool, int) {
	j := i
	for j < len(s) && !isNameEnd(s[j]) {
		j++
	}
	if j == i {
		return nil, false, i
	}
	node := &Node{Tag: stripPrefix(s[i:j]), Attrs: map[string]string{}}
	i = j
	for i < len(s) {
		for i < len(s) && isSpace(s[i]) {
			i++
		}
		if i >= len(s) {
			break
		}
		if s[i] == '>' {
			return node, false, i + 1
		}
		if s[i] == '/' {
			i++
			if i < len(s) && s[i] == '>' {
				return node, true, i + 1
			}
			continue
		}
		j = i
		for j < len(s) && !isNameEnd(s[j]) {
			j++
		}
		name := s[i:j]
		i = j
		for i < len(s) && isSpace(s[i]) {
			i++
		}
		if i >= len(s) || s[i] != '=' {
			continue // attribute without a value: ignore
		}
		i++
		for i < len(s) && isSpace(s[i]) {
			i++
		}
		if i >= len(s) {
			break
		}
		q := s[i]
		var val string
		if q == '"' || q == '\'' {
			k := strings.IndexByte(s[i+1:], q)
			if k < 0 {
				val = s[i+1:]
				i = len(s)
			} else {
				val = s[i+1 : i+1+k]
				i += k + 2
			}
		} else {
			j = i
			for j < len(s) && !isSpace(s[j]) && s[j] != '>' {
				j++
			}
			val = s[i:j]
			i = j
		}
		if name == "" {
			continue
		}
		if name == "xmlns" || strings.HasPrefix(name, "xmlns:") {
			continue
		}
		name = stripPrefix(name)
		node.Attrs[name] = decodeEntities(val)
	}
	return node, false, i
}

// decodeEntities resolves the five predefined entities and numeric character
// references; any other &...; sequence is left untouched.
func decodeEntities(v string) string {
	if !strings.Contains(v, "&") {
		return v
	}
	var b strings.Builder
	for i := 0; i < len(v); {
		if v[i] != '&' {
			b.WriteByte(v[i])
			i++
			continue
		}
		semi := strings.IndexByte(v[i:], ';')
		if semi < 0 {
			b.WriteString(v[i:])
			break
		}
		ent := v[i+1 : i+semi]
		if r, ok := decodeEntity(ent); ok {
			b.WriteString(r)
		} else {
			b.WriteString(v[i : i+semi+1])
		}
		i += semi + 1
	}
	return b.String()
}

func decodeEntity(ent string) (string, bool) {
	switch ent {
	case "amp":
		return "&", true
	case "lt":
		return "<", true
	case "gt":
		return ">", true
	case "quot":
		return "\"", true
	case "apos":
		return "'", true
	}
	if len(ent) > 1 && ent[0] == '#' {
		var n uint64
		var err error
		if ent[1] == 'x' || ent[1] == 'X' {
			n, err = strconv.ParseUint(ent[2:], 16, 32)
		} else {
			n, err = strconv.ParseUint(ent[1:], 10, 32)
		}
		if err == nil && n <= 0x10FFFF {
			return string(rune(n)), true
		}
	}
	return "", false
}
