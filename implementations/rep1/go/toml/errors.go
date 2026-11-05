package toml

import "fmt"

// SyntaxError reports why a document is not valid TOML.
type SyntaxError struct {
	Line   int    // 1-based line number
	Offset int    // byte offset into the document
	Msg    string // description of the problem
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("toml: line %d: %s", e.Line, e.Msg)
}

// lineOf returns the 1-based line number of byte offset off.
func lineOf(src []byte, off int) int {
	if off > len(src) {
		off = len(src)
	}
	line := 1
	for _, c := range src[:off] {
		if c == '\n' {
			line++
		}
	}
	return line
}
