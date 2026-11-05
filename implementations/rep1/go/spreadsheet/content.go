package spreadsheet

import (
	"errors"
	"strconv"

	"example.com/spreadsheet/formula"
)

// ErrContent is returned (wrapped) when the content given to Set is not a
// valid number literal, string literal or formula.
var ErrContent = errors.New("spreadsheet: invalid cell content")

// ErrCellName is returned when a cell name is not valid.
var ErrCellName = errors.New("spreadsheet: invalid cell name")

type contentKind uint8

const (
	contentEmpty contentKind = iota
	contentLiteral
	contentFormula
)

// parsedContent is the result of classifying the text given to Set.
type parsedContent struct {
	kind  contentKind
	value Value         // for contentLiteral
	expr  *formula.Expr // for contentFormula
}

// parseContent classifies cell content: a formula ("=..."), a string literal
// ("...") or a number literal.
func parseContent(s string) (parsedContent, error) {
	if s == "" {
		return parsedContent{}, ErrContent
	}
	switch s[0] {
	case '=':
		e, err := formula.Parse(s[1:])
		if err != nil {
			return parsedContent{}, errors.Join(ErrContent, err)
		}
		return parsedContent{kind: contentFormula, expr: e}, nil
	case '"':
		if len(s) < 2 || s[len(s)-1] != '"' {
			return parsedContent{}, ErrContent
		}
		inner := s[1 : len(s)-1]
		for i := 0; i < len(inner); i++ {
			if inner[i] == '"' || inner[i] == '\n' {
				return parsedContent{}, ErrContent
			}
		}
		return parsedContent{kind: contentLiteral, value: StringValue(inner)}, nil
	}
	if !isNumberLiteral(s) {
		return parsedContent{}, ErrContent
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return parsedContent{}, errors.Join(ErrContent, err)
	}
	return parsedContent{kind: contentLiteral, value: NumberValue(f)}, nil
}

// isNumberLiteral reports whether s matches -?[0-9]+(\.[0-9]+)?.
func isNumberLiteral(s string) bool {
	i := 0
	if i < len(s) && s[i] == '-' {
		i++
	}
	start := i
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	if i == start {
		return false
	}
	if i == len(s) {
		return true
	}
	if s[i] != '.' {
		return false
	}
	i++
	start = i
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	return i > start && i == len(s)
}
