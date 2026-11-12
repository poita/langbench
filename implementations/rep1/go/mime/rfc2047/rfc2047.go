// Package rfc2047 recognises and decodes RFC 2047 encoded words and builds the
// "unstructured" and "display" renderings of header text.
package rfc2047

import (
	"strings"

	"example.com/mime/charset"
	"example.com/mime/internal/lex"
	"example.com/mime/transfer"
)

// Match reports whether an encoded word starts at v[i]. If so it returns the
// decoded text and the index just past the word.
//
// An encoded word is "=?" charset "?" ("Q"|"B") "?" text "?=" where the
// charset is non-empty, and neither it nor the text contains SPACE or TAB. The
// first "?" after the charset and the first "?" after the encoding letter end
// their fields.
func Match(v string, i int) (text string, next int, ok bool) {
	if i+1 >= len(v) || v[i] != '=' || v[i+1] != '?' {
		return "", 0, false
	}
	j := strings.IndexByte(v[i+2:], '?')
	if j < 0 {
		return "", 0, false
	}
	j += i + 2
	cs := v[i+2 : j]
	if cs == "" || strings.ContainsAny(cs, " \t") {
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
	if strings.ContainsAny(body, " \t") {
		return "", 0, false
	}
	if m+1 >= len(v) || v[m+1] != '=' {
		return "", 0, false
	}
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
		raw = transfer.DecodeBase64([]byte(body))
	}
	return charset.Decode(raw, cs), m + 2, true
}

// decodeQ decodes the Q encoding: "_" is a space, "=XX" is a byte, and any
// other character stands for itself.
func decodeQ(s string) []byte {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '_':
			out = append(out, ' ')
		case c == '=' && i+2 < len(s) && transfer.HexValue(s[i+1]) >= 0 && transfer.HexValue(s[i+2]) >= 0:
			out = append(out, byte(transfer.HexValue(s[i+1])<<4|transfer.HexValue(s[i+2])))
			i += 2
		default:
			out = append(out, c)
		}
	}
	return out
}

type itemKind uint8

const (
	kindLiteral itemKind = iota
	kindSpace
	kindEncoded
)

type item struct {
	kind itemKind
	text string
}

// join concatenates items: a SPACE item between two ENCODED items vanishes.
func join(items []item) string {
	var b strings.Builder
	for i, it := range items {
		if it.kind == kindSpace && i > 0 && i+1 < len(items) &&
			items[i-1].kind == kindEncoded && items[i+1].kind == kindEncoded {
			continue
		}
		b.WriteString(it.text)
	}
	return lex.Strip(b.String())
}

// scan builds the item list of v. With display set, comments and quoted
// strings are handled as in a display name.
func scan(v string, display bool) []item {
	var items []item
	litStart, spStart := -1, -1
	flush := func(end int) {
		if litStart >= 0 {
			items = append(items, item{kindLiteral, v[litStart:end]})
			litStart = -1
		}
		if spStart >= 0 {
			items = append(items, item{kindSpace, v[spStart:end]})
			spStart = -1
		}
	}
	for i := 0; i < len(v); {
		c := v[i]
		if c == '=' {
			if text, next, ok := Match(v, i); ok {
				flush(i)
				items = append(items, item{kindEncoded, text})
				i = next
				continue
			}
		}
		if display {
			if c == '(' {
				flush(i)
				items = append(items, item{kindSpace, " "})
				i = lex.SkipComment(v, i)
				continue
			}
			if c == '"' {
				flush(i)
				text, next := lex.QuotedString(v, i)
				items = append(items, item{kindLiteral, text})
				i = next
				continue
			}
		}
		if lex.IsBlank(c) {
			if litStart >= 0 {
				items = append(items, item{kindLiteral, v[litStart:i]})
				litStart = -1
			}
			if spStart < 0 {
				spStart = i
			}
		} else {
			if spStart >= 0 {
				items = append(items, item{kindSpace, v[spStart:i]})
				spStart = -1
			}
			if litStart < 0 {
				litStart = i
			}
		}
		i++
	}
	flush(len(v))
	return items
}

// DecodeUnstructured decodes the encoded words in v. Blanks between two
// encoded words are dropped; all other text is kept, and leading and trailing
// SPACE and TAB are stripped from the result.
func DecodeUnstructured(v string) string {
	if !strings.Contains(v, "=?") {
		return lex.Strip(v)
	}
	return join(scan(v, false))
}

// DecodeDisplay is like DecodeUnstructured for the phrase of an address: each
// comment contributes one SPACE and quoted strings are taken literally (their
// encoded words are not decoded).
func DecodeDisplay(v string) string {
	return join(scan(v, true))
}
