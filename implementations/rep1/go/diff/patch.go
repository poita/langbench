package diff

import "fmt"

// Apply replays the script on a and returns the resulting lines.
//
// The Keep and Delete edits must, in order, be exactly the lines of a;
// otherwise Apply returns an error. The script need not be minimal.
func Apply(a []string, s Script) ([]string, error) {
	out := make([]string, 0, len(a))
	i := 0
	for n, e := range s {
		switch e.Op {
		case Keep, Delete:
			if i >= len(a) {
				return nil, fmt.Errorf("diff: edit %d consumes a line past the end of A", n+1)
			}
			if a[i] != e.Line {
				return nil, fmt.Errorf("diff: edit %d does not match line %d of A", n+1, i+1)
			}
			if e.Op == Keep {
				out = append(out, e.Line)
			}
			i++
		case Insert:
			out = append(out, e.Line)
		default:
			return nil, fmt.Errorf("diff: edit %d has invalid op %d", n+1, uint8(e.Op))
		}
	}
	if i != len(a) {
		return nil, fmt.Errorf("diff: script leaves %d lines of A unconsumed", len(a)-i)
	}
	return out, nil
}
