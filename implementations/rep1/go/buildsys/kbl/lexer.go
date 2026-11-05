package kbl

import "strings"

type tokKind uint8

const (
	tIdent tokKind = iota
	tInt
	tStr   // a quoted literal, text includes the quotes
	tPunct // ( ) [ ] { } , =
	tOp
)

type token struct {
	kind tokKind
	text string
	ival int64 // for tInt
}

func (t token) is(kind tokKind, text string) bool { return t.kind == kind && t.text == text }

// logicalLine is one logical line of a build file, tokenised.
type logicalLine struct {
	line int // 1-based number of the first physical line
	toks []token
}

var reserved = map[string]bool{
	"abort": true, "after": true, "cmd": true, "cost": true, "default": true,
	"depfile": true, "each": true, "elsewhen": true, "false": true, "in": true,
	"include": true, "let": true, "otherwise": true, "out": true, "phony": true,
	"rule": true, "set": true, "step": true, "true": true, "use": true, "when": true,
}

// skipString scans the string literal that starts at s[i] (a quote) using the
// shared literal scanner and returns the index just past its closing quote.
func skipString(s string, i int) (int, bool) {
	q := s[i]
	i++
	if q == '\'' {
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
	for i < len(s) {
		switch c := s[i]; c {
		case '\\':
			if i+1 >= len(s) {
				return 0, false
			}
			i += 2
		case '"':
			return i + 1, true
		case '{':
			if i+1 < len(s) && s[i+1] == '{' {
				i += 2
				continue
			}
			end, ok := skipRegion(s, i+1)
			if !ok {
				return 0, false
			}
			i = end
		case '}':
			if i+1 < len(s) && s[i+1] == '}' {
				i += 2
			} else {
				i++
			}
		default:
			i++
		}
	}
	return 0, false
}

// skipRegion scans an interpolation region whose body starts at s[i] and
// returns the index just past the closing brace.
func skipRegion(s string, i int) (int, bool) {
	depth := 1
	for i < len(s) {
		switch s[i] {
		case '"', '\'':
			end, ok := skipString(s, i)
			if !ok {
				return 0, false
			}
			i = end
		case '{':
			depth++
			i++
		case '}':
			depth--
			i++
			if depth == 0 {
				return i, true
			}
		default:
			i++
		}
	}
	return 0, false
}

// lexFile runs stages 1-3 over a whole build file. If the file has a lexical
// error it returns the line number of the logical line it belongs to
// (errLine > 0); the earliest one wins.
func lexFile(src string) (lines []logicalLine, errLine int) {
	physical := strings.Split(src, "\n")
	var (
		cur       strings.Builder
		depth     int
		startLine int
		have      bool
	)
	flush := func() bool {
		text := cur.String()
		cur.Reset()
		have = false
		if strings.Trim(text, " \t") == "" {
			return true
		}
		toks, ok := tokenize(text)
		if !ok {
			errLine = startLine
			return false
		}
		lines = append(lines, logicalLine{line: startLine, toks: toks})
		return true
	}
	for n, pl := range physical {
		if !have {
			startLine = n + 1
			have = true
		}
		stripped, ok := scanPhysical(pl, &depth)
		if !ok {
			return nil, startLine
		}
		if cur.Len() > 0 {
			cur.WriteByte(' ')
		}
		cur.WriteString(stripped)
		if depth == 0 {
			if !flush() {
				return nil, errLine
			}
		}
	}
	if depth > 0 {
		return nil, startLine
	}
	return lines, 0
}

// scanPhysical strips the comment from a physical line, updates the bracket
// depth and trims trailing blanks. ok is false on a lexical error.
func scanPhysical(s string, depth *int) (string, bool) {
	for i := 0; i < len(s); {
		switch c := s[i]; c {
		case '"', '\'':
			end, ok := skipString(s, i)
			if !ok {
				return "", false
			}
			i = end
			continue
		case '#':
			s = s[:i]
		case '(', '[':
			*depth++
		case ')', ']':
			*depth--
			if *depth < 0 {
				return "", false
			}
		}
		i++
	}
	return strings.TrimRight(s, " \t"), true
}

// tokenize splits text into tokens. It reports false on a byte that cannot
// begin a token or an unterminated literal.
func tokenize(s string) ([]token, bool) {
	var toks []token
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == ' ' || c == '\t':
			i++
		case c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z':
			j := i + 1
			for j < len(s) && (s[j] == '_' || s[j] >= 'a' && s[j] <= 'z' || s[j] >= 'A' && s[j] <= 'Z' || s[j] >= '0' && s[j] <= '9') {
				j++
			}
			toks = append(toks, token{kind: tIdent, text: s[i:j]})
			i = j
		case c >= '0' && c <= '9':
			j := i
			var v int64
			for j < len(s) && s[j] >= '0' && s[j] <= '9' {
				v = v*10 + int64(s[j]-'0')
				j++
			}
			toks = append(toks, token{kind: tInt, text: s[i:j], ival: v})
			i = j
		case c == '"' || c == '\'':
			end, ok := skipString(s, i)
			if !ok {
				return nil, false
			}
			toks = append(toks, token{kind: tStr, text: s[i:end]})
			i = end
		case strings.IndexByte("()[]{},", c) >= 0:
			toks = append(toks, token{kind: tPunct, text: s[i : i+1]})
			i++
		default:
			if i+1 < len(s) {
				switch s[i : i+2] {
				case "|>", "||", "&&", "==", "!=", "<=", ">=", "++":
					toks = append(toks, token{kind: tOp, text: s[i : i+2]})
					i += 2
					continue
				}
			}
			switch c {
			case '~', '+', '-', '*', '/', '%', '!', '<', '>':
				toks = append(toks, token{kind: tOp, text: s[i : i+1]})
			case '=':
				toks = append(toks, token{kind: tPunct, text: "="})
			default:
				return nil, false
			}
			i++
		}
	}
	return toks, true
}
