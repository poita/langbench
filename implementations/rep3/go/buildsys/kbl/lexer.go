package kbl

import "strings"

type tokKind uint8

const (
	tkIdent tokKind = iota
	tkInt
	tkStr   // a complete string literal, quotes included, parsed later
	tkPunct // ( ) [ ] { } , =
	tkOp
)

type token struct {
	kind tokKind
	text string
	ival int64
}

// logicalLine is one logical line of a build file: its tokens and the 1-based
// number of its first physical line.
type logicalLine struct {
	no   int
	toks []token
}

// SyntaxError is a lexical or grammatical error in a build file.
type SyntaxError struct {
	Line int
}

func (e *SyntaxError) Error() string { return "syntax error at line " + itoa(e.Line) }

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

// skipLiteral skips the string literal that opens at s[i] (a quote byte) by
// the rules shared by all three lexing stages and returns the index just past
// the closing quote. ok is false if the literal does not close.
func skipLiteral(s string, i int) (end int, ok bool) {
	if s[i] == '\'' {
		i++
		for i < len(s) {
			if s[i] == '\'' {
				if i+1 < len(s) && s[i+1] == '\'' {
					i += 2
					continue
				}
				return i + 1, true
			}
			i++
		}
		return 0, false
	}
	i++
	for i < len(s) {
		switch c := s[i]; c {
		case '\\':
			i += 2
		case '{':
			if i+1 < len(s) && s[i+1] == '{' {
				i += 2
				continue
			}
			i++
			depth := 1
			for depth > 0 {
				if i >= len(s) {
					return 0, false
				}
				switch s[i] {
				case '"', '\'':
					e, ok := skipLiteral(s, i)
					if !ok {
						return 0, false
					}
					i = e
					continue
				case '{':
					depth++
				case '}':
					depth--
				}
				i++
			}
		case '}':
			if i+1 < len(s) && s[i+1] == '}' {
				i += 2
			} else {
				i++
			}
		case '"':
			return i + 1, true
		default:
			i++
		}
	}
	return 0, false
}

// scanLine performs comment stripping and bracket counting on one physical
// line. It returns the line without its comment and trailing blanks and the
// new bracket depth; ok is false on a lexical error.
func scanLine(line string, depth int) (string, int, bool) {
	i := 0
scan:
	for i < len(line) {
		switch line[i] {
		case '"', '\'':
			e, ok := skipLiteral(line, i)
			if !ok {
				return "", 0, false
			}
			i = e
		case '#':
			line = line[:i]
			break scan
		case '(', '[':
			depth++
			i++
		case ')', ']':
			depth--
			if depth < 0 {
				return "", 0, false
			}
			i++
		default:
			i++
		}
	}
	return strings.TrimRight(line, " \t"), depth, true
}

// lexFile splits src into logical lines and tokenises them. The error, if
// any, is the lexical error belonging to the earliest logical line.
func lexFile(src string) ([]logicalLine, error) {
	var out []logicalLine
	var group strings.Builder
	depth, groupStart := 0, 0
	physical := strings.Split(src, "\n")
	for n, line := range physical {
		no := n + 1
		if depth == 0 {
			groupStart = no
			group.Reset()
		} else {
			group.WriteByte(' ')
		}
		stripped, d, ok := scanLine(line, depth)
		if !ok {
			return nil, &SyntaxError{groupStart}
		}
		depth = d
		group.WriteString(stripped)
		if depth > 0 {
			continue
		}
		toks, ok := tokenize(group.String())
		if !ok {
			return nil, &SyntaxError{groupStart}
		}
		if len(toks) > 0 {
			out = append(out, logicalLine{no: groupStart, toks: toks})
		}
	}
	if depth > 0 {
		return nil, &SyntaxError{groupStart}
	}
	return out, nil
}

func isIdentStart(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

var twoCharOps = []string{"|>", "||", "&&", "==", "!=", "<=", ">=", "++"}

// tokenize splits one logical line into tokens.
func tokenize(s string) ([]token, bool) {
	var toks []token
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == ' ' || c == '\t':
			i++
		case isIdentStart(c):
			j := i + 1
			for j < len(s) && (isIdentStart(s[j]) || isDigit(s[j])) {
				j++
			}
			toks = append(toks, token{kind: tkIdent, text: s[i:j]})
			i = j
		case isDigit(c):
			j := i
			var v uint64
			for j < len(s) && isDigit(s[j]) {
				v = v*10 + uint64(s[j]-'0')
				j++
			}
			toks = append(toks, token{kind: tkInt, text: s[i:j], ival: int64(v)})
			i = j
		case c == '"' || c == '\'':
			e, ok := skipLiteral(s, i)
			if !ok {
				return nil, false
			}
			toks = append(toks, token{kind: tkStr, text: s[i:e]})
			i = e
		default:
			if i+1 < len(s) {
				two := s[i : i+2]
				found := false
				for _, op := range twoCharOps {
					if two == op {
						toks = append(toks, token{kind: tkOp, text: op})
						i += 2
						found = true
						break
					}
				}
				if found {
					continue
				}
			}
			switch c {
			case '(', ')', '[', ']', '{', '}', ',', '=':
				toks = append(toks, token{kind: tkPunct, text: s[i : i+1]})
			case '<', '>', '~', '+', '-', '*', '/', '%', '!':
				toks = append(toks, token{kind: tkOp, text: s[i : i+1]})
			default:
				return nil, false
			}
			i++
		}
	}
	return toks, true
}
