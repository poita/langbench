package kbl

import (
	"errors"
	"strings"
)

// errSyntax is the generic syntax failure; callers attach the line number of
// the logical line being processed.
var errSyntax = errors.New("syntax error")

// syntaxError is an E_PARSE error attributed to a logical line.
type syntaxError struct{ line int }

func (e *syntaxError) Error() string { return "syntax error" }

type tokKind uint8

const (
	tIdent tokKind = iota
	tInt
	tStr   // text holds the raw literal, quotes included
	tPunct // ( ) [ ] { } , =
	tOp
)

type token struct {
	kind tokKind
	text string
	num  int64
}

func (t token) is(text string) bool { return (t.kind == tPunct || t.kind == tOp) && t.text == text }

type logicalLine struct {
	num  int
	toks []token
}

var reserved = map[string]bool{
	"abort": true, "after": true, "cmd": true, "cost": true, "default": true,
	"depfile": true, "each": true, "elsewhen": true, "false": true, "in": true,
	"include": true, "let": true, "otherwise": true, "out": true, "phony": true,
	"rule": true, "set": true, "step": true, "true": true, "use": true, "when": true,
}

// skipSQ returns the index just after the single-quoted literal whose content
// starts at s[i], or -1 if it is unterminated.
func skipSQ(s string, i int) int {
	for i < len(s) {
		if s[i] == '\'' {
			if i+1 < len(s) && s[i+1] == '\'' {
				i += 2
				continue
			}
			return i + 1
		}
		i++
	}
	return -1
}

// skipDQ returns the index just after the double-quoted literal whose content
// starts at s[i], or -1 if it is unterminated.
func skipDQ(s string, i int) int {
	for i < len(s) {
		switch s[i] {
		case '\\':
			i += 2
		case '"':
			return i + 1
		case '{':
			if i+1 < len(s) && s[i+1] == '{' {
				i += 2
				continue
			}
			i = skipRegion(s, i+1)
			if i < 0 {
				return -1
			}
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
	return -1
}

// skipRegion skips an interpolation region whose body starts at s[i] and
// returns the index just after its closing "}", or -1 if unterminated.
func skipRegion(s string, i int) int {
	depth := 1
	for i < len(s) {
		switch s[i] {
		case '"':
			i = skipDQ(s, i+1)
			if i < 0 {
				return -1
			}
		case '\'':
			i = skipSQ(s, i+1)
			if i < 0 {
				return -1
			}
		case '{':
			depth++
			i++
		case '}':
			depth--
			i++
			if depth == 0 {
				return i
			}
		default:
			i++
		}
	}
	return -1
}

// scanLine scans one physical line with the literal scanner. It returns the
// line with any comment removed and trailing blanks trimmed, and the updated
// bracket depth. ok is false on an unterminated literal or negative depth.
func scanLine(line string, depth int) (out string, newDepth int, ok bool) {
	i := 0
	for i < len(line) {
		switch c := line[i]; c {
		case '"':
			i = skipDQ(line, i+1)
			if i < 0 {
				return "", depth, false
			}
		case '\'':
			i = skipSQ(line, i+1)
			if i < 0 {
				return "", depth, false
			}
		case '#':
			return strings.TrimRight(line[:i], " \t"), depth, true
		case '(', '[':
			depth++
			i++
		case ')', ']':
			depth--
			if depth < 0 {
				return "", depth, false
			}
			i++
		default:
			i++
		}
	}
	return strings.TrimRight(line, " \t"), depth, true
}

func isIdentStart(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_'
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// tokenize splits text (a logical line or an interpolation body) into tokens.
func tokenize(text string) ([]token, error) {
	var toks []token
	for i := 0; i < len(text); {
		c := text[i]
		switch {
		case c == ' ' || c == '\t':
			i++
		case isIdentStart(c):
			j := i + 1
			for j < len(text) && (isIdentStart(text[j]) || isDigit(text[j])) {
				j++
			}
			toks = append(toks, token{kind: tIdent, text: text[i:j]})
			i = j
		case isDigit(c):
			j := i
			var n int64
			for j < len(text) && isDigit(text[j]) {
				n = n*10 + int64(text[j]-'0')
				j++
			}
			toks = append(toks, token{kind: tInt, text: text[i:j], num: n})
			i = j
		case c == '"' || c == '\'':
			var end int
			if c == '"' {
				end = skipDQ(text, i+1)
			} else {
				end = skipSQ(text, i+1)
			}
			if end < 0 {
				return nil, errSyntax
			}
			toks = append(toks, token{kind: tStr, text: text[i:end]})
			i = end
		default:
			if i+1 < len(text) {
				switch two := text[i : i+2]; two {
				case "|>", "||", "&&", "==", "!=", "<=", ">=", "++":
					toks = append(toks, token{kind: tOp, text: two})
					i += 2
					continue
				}
			}
			switch c {
			case '(', ')', '[', ']', '{', '}', ',', '=':
				toks = append(toks, token{kind: tPunct, text: text[i : i+1]})
			case '~', '+', '-', '*', '/', '%', '!', '<', '>':
				toks = append(toks, token{kind: tOp, text: text[i : i+1]})
			default:
				return nil, errSyntax
			}
			i++
		}
	}
	return toks, nil
}

// lexFile runs the three lexical stages over a whole build file. It returns
// the logical lines with their tokens, or a *syntaxError for the earliest
// logical line with a lexical error.
func lexFile(src string) ([]logicalLine, error) {
	physical := strings.Split(src, "\n")
	var lines []logicalLine
	var text strings.Builder
	depth, start := 0, 0
	for idx, pl := range physical {
		if start == 0 {
			start = idx + 1
			text.Reset()
		} else {
			text.WriteByte(' ')
		}
		stripped, d, ok := scanLine(pl, depth)
		if !ok {
			return nil, &syntaxError{start}
		}
		depth = d
		text.WriteString(stripped)
		if depth > 0 {
			continue
		}
		if strings.Trim(text.String(), " \t") != "" {
			toks, err := tokenize(text.String())
			if err != nil {
				return nil, &syntaxError{start}
			}
			lines = append(lines, logicalLine{num: start, toks: toks})
		}
		start = 0
	}
	if start != 0 {
		return nil, &syntaxError{start}
	}
	return lines, nil
}
