package linediff

// Tag is the kind of an edit operation. Its value is the character that
// introduces a line of the textual script format.
type Tag byte

const (
	// Keep means the line is present in both files.
	Keep Tag = ' '
	// Delete means the line of A is absent from B.
	Delete Tag = '-'
	// Insert means the line appears only in B.
	Insert Tag = '+'
)

// Op is one step of an edit script. For Keep and Delete, Index is the index
// of the line in A; for Insert it is the index of the line in B.
type Op struct {
	Tag   Tag
	Index int32
}

// Diff returns a minimal edit script turning a into b. Operations are in
// script order; the Keep and Delete operations visit a in order and the Keep
// and Insert operations visit b in order. The cost (the number of Delete plus
// Insert operations) is the smallest possible, N + M - 2*LCS(a, b).
func Diff(a, b [][]byte) []Op {
	ia, ib, _ := Intern(a, b)
	return DiffIDs(ia, ib)
}

// DiffStrings is Diff for slices of strings.
func DiffStrings(a, b []string) []Op {
	conv := func(s []string) [][]byte {
		out := make([][]byte, len(s))
		for i, x := range s {
			out[i] = []byte(x)
		}
		return out
	}
	return Diff(conv(a), conv(b))
}

// DiffIDs is the core of Diff on already-interned sequences: elements are
// equal exactly when their ids are equal. It returns a minimal edit script.
func DiffIDs(a, b []int32) []Op {
	s := newSearch(a, b)
	s.diff(0, len(a), 0, len(b))
	return s.ops
}

// Cost returns the number of Delete and Insert operations in ops.
func Cost(ops []Op) int {
	c := 0
	for _, op := range ops {
		if op.Tag != Keep {
			c++
		}
	}
	return c
}
