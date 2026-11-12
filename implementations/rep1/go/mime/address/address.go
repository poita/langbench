// Package address parses address-list header values (From, To, Cc, ...)
// leniently into display names and addr-specs.
package address

import (
	"strings"

	"example.com/mime/internal/lex"
	"example.com/mime/rfc2047"
)

// Address is one parsed address. Display is the decoded display name (possibly
// empty) and Spec the addr-spec, or the best-effort concatenation of the
// element's tokens when it is malformed.
type Address struct {
	Display string
	Spec    string
}

type tokKind uint8

const (
	tAtom tokKind = iota
	tQuoted
	tLiteral
	tEncoded
	tSpecial
)

type token struct {
	kind       tokKind
	text       string
	start, end int // byte range in the value
}

func (t token) isSpecial(c byte) bool {
	return t.kind == tSpecial && t.text[0] == c
}

const stops = " \t()<>[]@,:;.\"\\"

// tokenize splits an address-list value into tokens. Comments produce none.
func tokenize(v string) []token {
	var toks []token
	for i := 0; i < len(v); {
		c := v[i]
		switch {
		case c == ' ' || c == '\t':
			i++
		case c == '(':
			i = lex.SkipComment(v, i)
		case c == '"':
			text, next := lex.QuotedString(v, i)
			toks = append(toks, token{tQuoted, text, i, next})
			i = next
		case c == '[':
			j := i + 1
			for j < len(v) {
				if v[j] == '\\' {
					j += 2
					continue
				}
				if v[j] == ']' {
					j++
					break
				}
				j++
			}
			if j > len(v) {
				j = len(v)
			}
			toks = append(toks, token{tLiteral, v[i:j], i, j})
			i = j
		default:
			if c == '=' {
				if text, next, ok := rfc2047.Match(v, i); ok {
					toks = append(toks, token{tEncoded, text, i, next})
					i = next
					continue
				}
			}
			if strings.IndexByte("<>@,:;.", c) >= 0 {
				toks = append(toks, token{tSpecial, v[i : i+1], i, i + 1})
				i++
				continue
			}
			if strings.IndexByte(")]\\", c) >= 0 {
				toks = append(toks, token{tAtom, v[i : i+1], i, i + 1})
				i++
				continue
			}
			j := i + 1
			for j < len(v) && strings.IndexByte(stops, v[j]) < 0 {
				j++
			}
			toks = append(toks, token{tAtom, v[i:j], i, j})
			i = j
		}
	}
	return toks
}

// Parse parses the unfolded raw value of an address header.
func Parse(value string) []Address {
	toks := tokenize(value)
	var out []Address
	depth := 0
	start := 0
	for i, t := range toks {
		switch {
		case t.isSpecial('<'):
			depth++
		case t.isSpecial('>'):
			if depth > 0 {
				depth--
			}
		case t.isSpecial(',') && depth == 0:
			out = element(out, value, toks[start:i])
			start = i + 1
		}
	}
	return element(out, value, toks[start:])
}

func element(out []Address, value string, toks []token) []Address {
	// Group syntax: drop everything up to a ':' that precedes any '<' or '@'.
	for i, t := range toks {
		if t.isSpecial('<') || t.isSpecial('@') {
			break
		}
		if t.isSpecial(':') {
			toks = toks[i+1:]
			break
		}
	}
	if n := len(toks); n > 0 && toks[n-1].isSpecial(';') {
		toks = toks[:n-1]
	}
	if len(toks) == 0 {
		return out
	}
	// Alternative 1: [phrase] "<" addr-spec ">".
	lt := -1
	for i, t := range toks {
		if t.isSpecial('<') {
			lt = i
			break
		}
	}
	if lt >= 0 {
		gt := -1
		for i := len(toks) - 1; i > lt; i-- {
			if toks[i].isSpecial('>') {
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
	} else if spec, ok := addrSpec(toks); ok { // Alternative 2: addr-spec.
		return append(out, Address{"", spec})
	}
	var b strings.Builder
	for _, t := range toks {
		b.WriteString(t.text)
	}
	return append(out, Address{"", b.String()})
}

// dottedAtoms matches (ATOM|QUOTED) ("." (ATOM|QUOTED))* — quoted allows
// QUOTED tokens — and returns the number of tokens consumed and their texts
// joined by ".". It requires strict alternation.
func dotted(toks []token, allowQuoted bool) (text string, n int) {
	var parts []string
	for i := 0; i < len(toks); i++ {
		t := toks[i]
		if t.kind == tAtom || (allowQuoted && t.kind == tQuoted) {
			parts = append(parts, t.text)
			n = i + 1
			if i+1 < len(toks) && toks[i+1].isSpecial('.') {
				i++
				if i+1 >= len(toks) {
					return "", 0 // trailing dot
				}
				continue
			}
			return strings.Join(parts, "."), n
		}
		return "", 0
	}
	return "", 0
}

// addrSpec matches local "@" domain over the whole of toks.
func addrSpec(toks []token) (string, bool) {
	local, n := dotted(toks, true)
	if n == 0 {
		return "", false
	}
	rest := toks[n:]
	if len(rest) == 0 {
		return local, true
	}
	if !rest[0].isSpecial('@') {
		return "", false
	}
	rest = rest[1:]
	if len(rest) == 1 && rest[0].kind == tLiteral {
		return local + "@" + rest[0].text, true
	}
	domain, m := dotted(rest, false)
	if m == 0 || m != len(rest) {
		return "", false
	}
	return local + "@" + domain, true
}
