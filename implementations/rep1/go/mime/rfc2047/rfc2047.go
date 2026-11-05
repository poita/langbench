// Package rfc2047 recognises and decodes RFC 2047 encoded words and builds
// the two header-text renderings used by the dump format: DecodeUnstructured
// (for unstructured fields and plain parameter values) and DecodeDisplay (for
// address phrases).
package rfc2047

import (
	"strings"

	"mimedump/charset"
	"mimedump/internal/scan"
	"mimedump/transfer"
)

// Match reports whether an encoded word starts at v[i]. If so it returns the
// decoded text and the index just after the word.
//
// The word is "=?" charset "?" (Q|q|B|b) "?" text "?=" where the charset is
// non-empty, neither charset nor text contains SPACE or TAB, and the first
// "?" after the charset and the first "?" after the encoding letter delimit
// the fields.
func Match(v string, i int) (text string, end int, ok bool) {
	if i+1 >= len(v) || v[i] != '=' || v[i+1] != '?' {
		return "", 0, false
	}
	j := strings.IndexByte(v[i+2:], '?')
	if j < 0 {
		return "", 0, false
	}
	j += i + 2
	csField := v[i+2 : j]
	if csField == "" || strings.ContainsAny(csField, " \t") {
		return "", 0, false
	}
	if j+2 >= len(v) || v[j+2] != '?' {
		return "", 0, false
	}
	enc := v[j+1]
	if enc != 'Q' && enc != 'q' && enc != 'B' && enc != 'b' {
		return "", 0, false
	}
	m := strings.IndexByte(v[j+3:], '?')
	if m < 0 {
		return "", 0, false
	}
	m += j + 3
	body := v[j+3 : m]
	if strings.ContainsAny(body, " \t") || m+1 >= len(v) || v[m+1] != '=' {
		return "", 0, false
	}

	cs := csField
	if k := strings.IndexByte(cs, '*'); k >= 0 {
		cs = cs[:k]
	}
	cs = charset.Normalize(cs)
	if cs == "" {
		cs = "us-ascii"
	}
	var raw []byte
	if enc == 'Q' || enc == 'q' {
		raw = decodeQ(body)
	} else {
		raw = transfer.Base64(body)
	}
	return charset.Decode(raw, cs), m + 2, true
}

// decodeQ decodes the Q encoding: "_" is a space, "=HH" is a byte, and any
// other character stands for its own UTF-8 bytes.
func decodeQ(s string) []byte {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '_':
			out = append(out, ' ')
		case c == '=' && i+2 < len(s) && scan.HexVal(s[i+1]) >= 0 && scan.HexVal(s[i+2]) >= 0:
			out = append(out, byte(scan.HexVal(s[i+1])<<4|scan.HexVal(s[i+2])))
			i += 2
		default:
			out = append(out, c)
		}
	}
	return out
}

type kind uint8

const (
	kLiteral kind = iota
	kSpace
	kEncoded
)

type item struct {
	kind kind
	text string
}

// DecodeUnstructured decodes encoded words in v. Blanks between two adjacent
// encoded words are dropped; all other text is kept, and the result is
// stripped of leading and trailing SPACE and TAB.
func DecodeUnstructured(v string) string { return decode(v, false) }

// DecodeDisplay is DecodeUnstructured with two extra rules for address
// phrases: a comment becomes a single space, and a quoted string becomes a
// literal holding its unescaped contents (encoded words inside it are not
// decoded).
func DecodeDisplay(v string) string { return decode(v, true) }

func decode(v string, display bool) string {
	var items []item
	for i := 0; i < len(v); {
		c := v[i]
		if c == '=' {
			if text, end, ok := Match(v, i); ok {
				items = append(items, item{kEncoded, text})
				i = end
				continue
			}
		}
		if display && c == '(' {
			items = append(items, item{kSpace, " "})
			i = scan.Comment(v, i)
			continue
		}
		if display && c == '"' {
			text, end := scan.Quoted(v, i)
			items = append(items, item{kLiteral, text})
			i = end
			continue
		}
		j := i + 1
		if scan.IsBlank(c) {
			for j < len(v) && scan.IsBlank(v[j]) {
				j++
			}
			items = append(items, item{kSpace, v[i:j]})
		} else {
			for j < len(v) && !scan.IsBlank(v[j]) && v[j] != '=' && !(display && (v[j] == '(' || v[j] == '"')) {
				j++
			}
			items = append(items, item{kLiteral, v[i:j]})
		}
		i = j
	}

	var sb strings.Builder
	sb.Grow(len(v))
	for k, it := range items {
		if it.kind == kSpace && k > 0 && k+1 < len(items) &&
			items[k-1].kind == kEncoded && items[k+1].kind == kEncoded {
			continue
		}
		sb.WriteString(it.text)
	}
	return scan.Trim(sb.String())
}
