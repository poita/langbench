// Package diag defines the single error type used by every stage of the
// typesetter that can reject its input: a file name, a 1-based line and
// column, and one of the error codes listed in the specification.
package diag

import "fmt"

// Error is a located input error. Only the first error found is ever
// reported.
type Error struct {
	File string // "settings.cfg", "document.cdx" or "-"
	Line int    // 1-based line number (0 for missing-document)
	Col  int    // 1-based column in Unicode scalar values
	Code string // e.g. "bad-length"
}

// Error implements the error interface and renders the canonical
// "<file>:<line>:<col>: <code>" form written to error.txt.
func (e *Error) Error() string {
	return fmt.Sprintf("%s:%d:%d: %s", e.File, e.Line, e.Col, e.Code)
}

// New returns a new located error.
func New(file string, line, col int, code string) *Error {
	return &Error{File: file, Line: line, Col: col, Code: code}
}
