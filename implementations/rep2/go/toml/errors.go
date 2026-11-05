package toml

import "fmt"

// Error describes why a document could not be parsed.
type Error struct {
	Offset int    // byte offset into the input where the problem was detected
	Line   int    // 1-based line number of Offset
	Col    int    // 1-based byte column of Offset
	Msg    string // short description
}

func (e *Error) Error() string {
	return fmt.Sprintf("toml: line %d, column %d: %s", e.Line, e.Col, e.Msg)
}

// newError builds an Error for offset off in src.
func newError(src []byte, off int, msg string) *Error {
	if off > len(src) {
		off = len(src)
	}
	if off < 0 {
		off = 0
	}
	line, col := 1, 1
	for _, b := range src[:off] {
		if b == '\n' {
			line++
			col = 1
		} else {
			col++
		}
	}
	return &Error{Offset: off, Line: line, Col: col, Msg: msg}
}
