// Package address parses RFC 5322 address-list header values (From, To, Cc,
// ...) into display name and address pairs. The grammar is deliberately
// forgiving: anything that is not a well-formed mailbox still yields an
// address whose spec is the concatenation of the element's tokens.
package address

import (
	"strings"

	"mimedump/internal/scan"
	"mimedump/rfc2047"
)

// Address is one parsed mailbox.
type Address struct {
	Display string
	Spec    string
}

type tokKind uint8

const (
	atom tokKind = iota
	quoted
	literal
	encoded
	special
)

type token struct {
	kind  tokKind
	text  string
	start int // offset of the token's first byte in the header value
}

func (t token) is(c byte) bool { return t.kind == special && t.text[0] == c }

const specials = "<>@,:;."
const atomStop = " \t()<>[]@,:;.\"\\"

func tokenize(v string) []token {
	var toks []token
	for i := 0; i < len(v); {
		c := v[i]
		switch {
		case scan.IsBlank(c):
			i++
		case c == '(':
			i = scan.Comment(v, i)
		case c == '"':
			text, end := scan.Quoted(v, i)
			toks = append(toks, token{quoted, text, i})
			i = end
		case c == '[':
			end := scan.Literal(v, i)
			toks = append(toks, token{literal, v[i:end], i})
			i = end
		default:
			if c == '=' {
				if text, end, ok := rfc2047.Match(v, i); ok {
					toks = append(toks, token{encoded, text, i})
					i = end
					continue
				}
			}
			if strings.IndexByte(specials, c) >= 0 {
				toks = append(toks, token{special, v[i : i+1], i})
				i++
				continue
			}
			j := i + 1
			for j < len(v) && strings.IndexByte(atomStop, v[j]) < 0 {
				j++
			}
			toks = append(toks, token{atom, v[i:j], i})
			i = j
		}
	}
	return toks
}

// ParseList parses the unfolded raw value of an address header.
func ParseList(value string) []Address {
	toks := tokenize(value)
	var out []Address
	depth, start := 0, 0
	for i, t := range toks {
		switch {
		case t.is('<'):
			depth++
		case t.is('>'):
			if depth > 0 {
				depth--
			}
		case t.is(',') && depth == 0:
			out = element(out, value, toks[start:i])
			start = i + 1
		}
	}
	return element(out, value, toks[start:])
}

// element converts one comma-separated element into an address, if any.
func element(out []Address, value string, toks []token) []Address {
	// Group syntax: drop "name :" when the first of < @ : is a colon.
	for i, t := range toks {
		if t.is('<') || t.is('@') {
			break
		}
		if t.is(':') {
			toks = toks[i+1:]
			break
		}
	}
	if n := len(toks); n > 0 && toks[n-1].is(';') {
		toks = toks[:n-1]
	}
	if len(toks) == 0 {
		return out
	}

	// 1. [phrase] < addr-spec >
	lt := -1
	for i, t := range toks {
		if t.is('<') {
			lt = i
			break
		}
	}
	if lt >= 0 {
		gt := -1
		for i := len(toks) - 1; i > lt; i-- {
			if toks[i].is('>') {
				gt = i
				break
			}
		}
		if gt >= 0 {
			if spec, ok := addrSpec(toks[lt+1 : gt]); ok {
				display := ""
				if lt > 0 {
					display = rfc2047.DecodeDisplay(value[toks[0].start:toks[lt].start])
				}
				return append(out, Address{display, spec})
			}
		}
	} else if spec, ok := addrSpec(toks); ok {
		// 2. addr-spec
		return append(out, Address{"", spec})
	}

	var sb strings.Builder
	for _, t := range toks {
		sb.WriteString(t.text)
	}
	return append(out, Address{"", sb.String()})
}

// addrSpec renders local@domain, or just local when there is no '@'.
func addrSpec(toks []token) (string, bool) {
	at := -1
	for i, t := range toks {
		if t.is('@') {
			at = i
			break
		}
	}
	if at < 0 {
		return dotted(toks, atom, quoted)
	}
	local, ok := dotted(toks[:at], atom, quoted)
	if !ok {
		return "", false
	}
	dom := toks[at+1:]
	if len(dom) == 1 && dom[0].kind == literal {
		return local + "@" + dom[0].text, true
	}
	domain, ok := dotted(dom, atom, atom)
	if !ok {
		return "", false
	}
	return local + "@" + domain, true
}

// dotted accepts a non-empty alternation word ('.' word)* where each word has
// kind k1 or k2, and returns the words joined with '.'.
func dotted(toks []token, k1, k2 tokKind) (string, bool) {
	if len(toks) == 0 || len(toks)%2 == 0 {
		return "", false
	}
	var sb strings.Builder
	for i, t := range toks {
		if i%2 == 1 {
			if !t.is('.') {
				return "", false
			}
			sb.WriteByte('.')
		} else {
			if t.kind != k1 && t.kind != k2 {
				return "", false
			}
			sb.WriteString(t.text)
		}
	}
	return sb.String(), true
}
