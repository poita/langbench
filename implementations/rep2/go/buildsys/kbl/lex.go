package kbl

import "strings"

// TokKind classifies a token.
type TokKind uint8

// Token kinds.
const (
	TokIdent TokKind = iota
	TokInt
	TokStr
	TokPunct // ( ) [ ] { } , =
	TokOp    // |> || && == != <= >= < > ++ ~ + - * / % !
)

// Token is a lexical token. For TokStr, Text is the raw literal content
// between the quotes and Double tells which quote style was used.
type Token struct {
	Kind   TokKind
	Text   string
	Double bool
	Int    int64
}

// Line is a logical line: its first physical line number and its tokens.
type Line struct {
	Num  int
	Toks []Token
}

// ParseError is a syntax error at a logical line.
type ParseError struct{ Line int }

// Error implements error.
func (e *ParseError) Error() string { return "parse error" }

// skipSingle skips a single-quoted literal whose opening quote is at s[i] and
// returns the index just past the closing quote, or -1 if unterminated.
func skipSingle(s string, i int) int {
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

// skipDouble skips a double-quoted literal whose opening quote is at s[i] and
// returns the index just past the closing quote, or -1 if unterminated.
func skipDouble(s string, i int) int {
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
			i = skipInterp(s, i)
			if i < 0 {
				return -1
			}
		default:
			i++
		}
	}
	return -1
}

// skipInterp skips an interpolation region whose opening brace is at s[i] and
// returns the index just past its closing brace, or -1 if unterminated.
func skipInterp(s string, i int) int {
	depth := 1
	i++
	for i < len(s) {
		switch s[i] {
		case '"':
			i = skipDouble(s, i)
			if i < 0 {
				return -1
			}
		case '\'':
			i = skipSingle(s, i)
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

// Lex performs comment stripping, logical-line assembly and tokenisation of a
// whole build file. It returns a *ParseError for the earliest lexical error.
func Lex(src string) ([]Line, error) {
	var lines []Line
	phys := strings.Split(src, "\n")
	if n := len(phys); n > 0 && phys[n-1] == "" {
		phys = phys[:n-1]
	}
	var group strings.Builder
	depth, start := 0, 0
	for idx, p := range phys {
		if depth == 0 && group.Len() == 0 {
			start = idx + 1
		}
		text, delta, ok := stripLine(p, depth)
		if !ok {
			return nil, &ParseError{Line: start}
		}
		depth += delta
		if group.Len() > 0 {
			group.WriteByte(' ')
		}
		group.WriteString(text)
		if depth > 0 {
			continue
		}
		logical := group.String()
		group.Reset()
		if strings.Trim(logical, " \t") == "" {
			continue
		}
		toks, err := Tokenize(logical)
		if err != nil {
			return nil, &ParseError{Line: start}
		}
		lines = append(lines, Line{Num: start, Toks: toks})
	}
	if depth > 0 {
		return nil, &ParseError{Line: start}
	}
	return lines, nil
}

// stripLine removes the comment from a physical line and returns the text with
// trailing blanks trimmed plus the net bracket-depth change. ok is false for an
// unterminated literal or a negative bracket depth.
func stripLine(s string, depth int) (string, int, bool) {
	delta := 0
	end := len(s)
scan:
	for i := 0; i < len(s); {
		switch s[i] {
		case '"':
			i = skipDouble(s, i)
			if i < 0 {
				return "", 0, false
			}
		case '\'':
			i = skipSingle(s, i)
			if i < 0 {
				return "", 0, false
			}
		case '#':
			end = i
			break scan
		case '(', '[':
			delta++
			i++
		case ')', ']':
			delta--
			if depth+delta < 0 {
				return "", 0, false
			}
			i++
		default:
			i++
		}
	}
	return strings.TrimRight(s[:end], " \t"), delta, true
}

// Tokenize splits text into tokens. Literals are kept raw; their contents are
// interpreted by the parser.
func Tokenize(s string) ([]Token, error) {
	var toks []Token
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
			toks = append(toks, Token{Kind: TokIdent, Text: s[i:j]})
			i = j
		case c >= '0' && c <= '9':
			j := i
			var v int64
			for j < len(s) && s[j] >= '0' && s[j] <= '9' {
				v = v*10 + int64(s[j]-'0')
				j++
			}
			toks = append(toks, Token{Kind: TokInt, Text: s[i:j], Int: v})
			i = j
		case c == '"':
			j := skipDouble(s, i)
			if j < 0 {
				return nil, &ParseError{}
			}
			toks = append(toks, Token{Kind: TokStr, Text: s[i+1 : j-1], Double: true})
			i = j
		case c == '\'':
			j := skipSingle(s, i)
			if j < 0 {
				return nil, &ParseError{}
			}
			toks = append(toks, Token{Kind: TokStr, Text: s[i+1 : j-1]})
			i = j
		default:
			if i+1 < len(s) {
				switch s[i : i+2] {
				case "|>", "||", "&&", "==", "!=", "<=", ">=", "++":
					toks = append(toks, Token{Kind: TokOp, Text: s[i : i+2]})
					i += 2
					continue
				}
			}
			switch c {
			case '(', ')', '[', ']', '{', '}', ',', '=':
				toks = append(toks, Token{Kind: TokPunct, Text: s[i : i+1]})
			case '<', '>', '~', '+', '-', '*', '/', '%', '!':
				toks = append(toks, Token{Kind: TokOp, Text: s[i : i+1]})
			default:
				return nil, &ParseError{}
			}
			i++
		}
	}
	return toks, nil
}
