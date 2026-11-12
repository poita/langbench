package diff

import (
	"fmt"
	"strings"
)

// Op is the kind of an [Edit].
type Op uint8

// The edit operations.
const (
	Keep   Op = iota // the next line of A also appears in B
	Delete           // the next line of A does not appear in B
	Insert           // a line of B that does not come from A
)

// Tag returns the script tag character of the operation: ' ', '-' or '+'.
func (o Op) Tag() byte {
	switch o {
	case Keep:
		return ' '
	case Delete:
		return '-'
	case Insert:
		return '+'
	}
	return '?'
}

func (o Op) String() string {
	switch o {
	case Keep:
		return "keep"
	case Delete:
		return "delete"
	case Insert:
		return "insert"
	}
	return fmt.Sprintf("Op(%d)", uint8(o))
}

// Edit is a single step of an edit script.
type Edit struct {
	Op   Op
	Line string // the line's text, without a line terminator
}

// String renders the edit in script form: the tag character then the line.
func (e Edit) String() string { return string(e.Op.Tag()) + e.Line }

// Script is an ordered sequence of edits.
type Script []Edit

// Cost returns the number of Delete and Insert edits in the script.
func (s Script) Cost() int {
	n := 0
	for _, e := range s {
		if e.Op != Keep {
			n++
		}
	}
	return n
}

// String renders the script in its text form, one edit per line, each line
// terminated by '\n'.
func (s Script) String() string {
	var sb strings.Builder
	for _, e := range s {
		sb.WriteByte(e.Op.Tag())
		sb.WriteString(e.Line)
		sb.WriteByte('\n')
	}
	return sb.String()
}

// ParseLine parses one script line (without its terminator): a tag character
// (' ', '-' or '+') followed by the line's text.
func ParseLine(s string) (Edit, error) {
	if s == "" {
		return Edit{}, fmt.Errorf("diff: empty script line")
	}
	var op Op
	switch s[0] {
	case ' ':
		op = Keep
	case '-':
		op = Delete
	case '+':
		op = Insert
	default:
		return Edit{}, fmt.Errorf("diff: invalid script tag %q", s[0])
	}
	return Edit{Op: op, Line: s[1:]}, nil
}

// ParseScript parses script lines (each a tag followed by text, without
// terminators) into a Script.
func ParseScript(lines []string) (Script, error) {
	s := make(Script, len(lines))
	for i, l := range lines {
		e, err := ParseLine(l)
		if err != nil {
			return nil, fmt.Errorf("script line %d: %w", i+1, err)
		}
		s[i] = e
	}
	return s, nil
}
