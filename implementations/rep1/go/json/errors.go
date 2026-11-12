package jsoncanon

import "strconv"

// SyntaxError describes why a document was rejected.
type SyntaxError struct {
	// Offset is the byte offset in the input at which the problem was detected.
	Offset int
	// Msg describes the problem.
	Msg string
}

func (e *SyntaxError) Error() string {
	return "jsoncanon: " + e.Msg + " at offset " + strconv.Itoa(e.Offset)
}
