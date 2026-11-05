package kbl

import (
	"strings"

	"kiln/errs"
)

// tokKind classifies a token.
type tokKind uint8

const (
	tIdent tokKind = iota
	tInt
	tStr // raw literal text including its quotes
	tOp  // punctuation or operator; text holds the spelling
)

type token struct {
	kind tokKind
	text string
	num  int64 // value of a tInt
}

func (t token) is(op string) bool { return t.kind == tOp && t.text == op }

// logicalLine is one logical line of a build file after comment stripping
// and bracket joining, already tokenised.
type logicalLine struct {
	line int // 1-based number of the first physical line
	toks []token
}

// skipDQ returns the index just past the double-quoted literal that opens at
// s[i], or -1 if it is unterminated.
func skipDQ(s string, i int) int {
	i++
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
			i = skipInterp(s, i+1)
			if i < 0 {
				return -1
			}
		default:
			i++
		}
	}
	return -1
}

// skipInterp scans an interpolation region whose body starts at s[i] and
// returns the index just past its closing '}', or -1.
func skipInterp(s string, i int) int {
	depth := 1
	for i < len(s) {
		switch s[i] {
		case '"':
			i = skipDQ(s, i)
			if i < 0 {
				return -1
			}
			continue
		case '\'':
			i = skipSQ(s, i)
			if i < 0 {
				return -1
			}
			continue
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return i + 1
			}
		}
		i++
	}
	return -1
}

// skipSQ returns the index just past the single-quoted literal that opens
// at s[i], or -1 if it is unterminated.
func skipSQ(s string, i int) int {
	i++
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

// scanPhysical strips the comment from one physical line and updates the
// bracket depth. ok is false on a lexical error.
func scanPhysical(line string, depth int) (stripped string, newDepth int, ok bool) {
	for i := 0; i < len(line); {
		switch line[i] {
		case '"':
			i = skipDQ(line, i)
			if i < 0 {
				return "", depth, false
			}
		case '\'':
			i = skipSQ(line, i)
			if i < 0 {
				return "", depth, false
			}
		case '#':
			return line[:i], depth, true
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
	return line, depth, true
}

func trimRight(s string) string {
	n := len(s)
	for n > 0 && (s[n-1] == ' ' || s[n-1] == '\t') {
		n--
	}
	return s[:n]
}

func isBlank(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] != ' ' && s[i] != '\t' {
			return false
		}
	}
	return true
}

// lexFile performs the three lexical stages over a whole build file. On
// failure it returns the line number of the offending logical line.
func lexFile(src string) (lines []logicalLine, errLine int, ok bool) {
	var physical []string
	if src != "" {
		physical = strings.Split(src, "\n")
		if physical[len(physical)-1] == "" {
			physical = physical[:len(physical)-1]
		}
	}
	depth := 0
	cur := ""
	curStart := 0
	joining := false
	for i, line := range physical {
		if !joining {
			curStart = i + 1
		}
		stripped, nd, ok := scanPhysical(line, depth)
		if !ok {
			return nil, curStart, false
		}
		stripped = trimRight(stripped)
		if joining {
			cur += " " + stripped
		} else {
			cur = stripped
		}
		depth = nd
		if depth > 0 {
			joining = true
			continue
		}
		joining = false
		if isBlank(cur) {
			continue
		}
		toks, ok := tokenize(cur)
		if !ok {
			return nil, curStart, false
		}
		lines = append(lines, logicalLine{line: curStart, toks: toks})
	}
	if depth > 0 {
		return nil, curStart, false
	}
	return lines, 0, true
}

func isIdentStart(c byte) bool { return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }
func isDigit(c byte) bool      { return c >= '0' && c <= '9' }

// tokenize splits text into tokens; ok is false for a byte that cannot
// begin a token or an unterminated literal.
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
			toks = append(toks, token{kind: tIdent, text: s[i:j]})
			i = j
		case isDigit(c):
			j := i
			var n int64
			for j < len(s) && isDigit(s[j]) {
				n = n*10 + int64(s[j]-'0')
				j++
			}
			toks = append(toks, token{kind: tInt, text: s[i:j], num: n})
			i = j
		case c == '"' || c == '\'':
			var j int
			if c == '"' {
				j = skipDQ(s, i)
			} else {
				j = skipSQ(s, i)
			}
			if j < 0 {
				return nil, false
			}
			toks = append(toks, token{kind: tStr, text: s[i:j]})
			i = j
		default:
			n := opLen(s[i:])
			if n == 0 {
				return nil, false
			}
			toks = append(toks, token{kind: tOp, text: s[i : i+n]})
			i += n
		}
	}
	return toks, true
}

func opLen(s string) int {
	if len(s) >= 2 {
		switch s[:2] {
		case "|>", "||", "&&", "==", "!=", "<=", ">=", "++":
			return 2
		}
	}
	switch s[0] {
	case '(', ')', '[', ']', '{', '}', ',', '=', '<', '>', '~', '+', '-', '*', '/', '%', '!':
		return 1
	}
	return 0
}

func parseErr(file string, line int) *errs.Error {
	return errs.New(errs.Parse, "%s:%d", file, line)
}
