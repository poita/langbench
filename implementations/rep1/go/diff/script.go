package linediff

import (
	"errors"
	"strconv"
)

// Edit is one parsed line of a textual edit script: a tag and the line text.
// Text is a view into the buffer it was parsed from.
type Edit struct {
	Tag  Tag
	Text []byte
}

// ErrBadTag is returned by ParseScript for a script line that is empty or
// starts with something other than ' ', '-' or '+'.
var ErrBadTag = errors.New("linediff: invalid script line tag")

// AppendScript appends the textual form of ops (the script that Diff(a, b)
// returned) to dst and returns the extended slice: first a line with the
// number of operations, then one line per operation consisting of the tag
// character immediately followed by the line text, each ending in "\n".
func AppendScript(dst []byte, a, b [][]byte, ops []Op) []byte {
	size := 12
	for _, op := range ops {
		size += 2 + len(lineOf(a, b, op))
	}
	if cap(dst)-len(dst) < size {
		grown := make([]byte, len(dst), len(dst)+size)
		copy(grown, dst)
		dst = grown
	}
	dst = strconv.AppendInt(dst, int64(len(ops)), 10)
	dst = append(dst, '\n')
	for _, op := range ops {
		dst = append(dst, byte(op.Tag))
		dst = append(dst, lineOf(a, b, op)...)
		dst = append(dst, '\n')
	}
	return dst
}

func lineOf(a, b [][]byte, op Op) []byte {
	if op.Tag == Insert {
		return b[op.Index]
	}
	return a[op.Index]
}

// ParseScript parses script lines (without their terminators) in the textual
// format into edits. The first byte of each line is the tag and the remainder
// is the text, which may be empty.
func ParseScript(lines [][]byte) ([]Edit, error) {
	edits := make([]Edit, len(lines))
	for i, l := range lines {
		if len(l) == 0 {
			return nil, ErrBadTag
		}
		switch t := Tag(l[0]); t {
		case Keep, Delete, Insert:
			edits[i] = Edit{t, l[1:]}
		default:
			return nil, ErrBadTag
		}
	}
	return edits, nil
}

// EditsOf converts ops into edits carrying the line text, the inverse of
// ParseScript(AppendScript(...)) up to the count line.
func EditsOf(a, b [][]byte, ops []Op) []Edit {
	edits := make([]Edit, len(ops))
	for i, op := range ops {
		edits[i] = Edit{op.Tag, lineOf(a, b, op)}
	}
	return edits
}
