package jsoncanon

import "strconv"

// SyntaxError describes why a document was rejected.
type SyntaxError struct {
	// Offset is the byte offset in the input at which the problem was found.
	Offset int
	// Msg is a short human-readable description.
	Msg string
}

func (e *SyntaxError) Error() string {
	return "jsoncanon: " + e.Msg + " at offset " + strconv.Itoa(e.Offset)
}
