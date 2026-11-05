package toml

import "fmt"

// SyntaxError reports why a document was rejected.
type SyntaxError struct {
	Offset int    // byte offset in the document where the problem was detected
	Line   int    // 1-based line number of Offset
	Msg    string // human-readable description
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("toml: line %d (offset %d): %s", e.Line, e.Offset, e.Msg)
}

// parseAbort is the panic payload used to unwind the recursive-descent parser.
type parseAbort struct {
	off int
	msg string
}

func newSyntaxError(src []byte, off int, msg string) *SyntaxError {
	if off > len(src) {
		off = len(src)
	}
	line := 1
	for _, c := range src[:off] {
		if c == '\n' {
			line++
		}
	}
	return &SyntaxError{Offset: off, Line: line, Msg: msg}
}
