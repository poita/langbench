package regex

import "fmt"

// SyntaxError describes a pattern that is not valid in the supported
// syntax. Offset is the byte offset in the pattern where the problem was
// detected.
type SyntaxError struct {
	Pattern string
	Offset  int
	Msg     string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("regex: invalid pattern %q at offset %d: %s", e.Pattern, e.Offset, e.Msg)
}

// LimitError is returned by Compile when a pattern is syntactically valid
// but expands to more than the supported amount of program text, for example
// through deeply nested counted quantifiers.
type LimitError struct {
	Pattern string
	Msg     string
}

func (e *LimitError) Error() string {
	return fmt.Sprintf("regex: pattern %q exceeds limits: %s", e.Pattern, e.Msg)
}
