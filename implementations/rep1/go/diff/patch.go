package linediff

import (
	"bytes"
	"errors"
)

// ErrMismatch is returned by Apply when the script does not match the file
// it is applied to.
var ErrMismatch = errors.New("linediff: script does not match the original file")

// Apply applies a script to the lines of a and returns the resulting lines.
// Keep and Delete edits must consume the lines of a, in order and with
// identical text, and must consume all of them; otherwise ErrMismatch is
// returned. The result's slices are views of a and of the edits' text.
func Apply(a [][]byte, script []Edit) ([][]byte, error) {
	out := make([][]byte, 0, len(a)+len(script))
	i := 0
	for _, e := range script {
		switch e.Tag {
		case Keep, Delete:
			if i >= len(a) || !bytes.Equal(a[i], e.Text) {
				return nil, ErrMismatch
			}
			if e.Tag == Keep {
				out = append(out, a[i])
			}
			i++
		case Insert:
			out = append(out, e.Text)
		default:
			return nil, ErrBadTag
		}
	}
	if i != len(a) {
		return nil, ErrMismatch
	}
	return out, nil
}
