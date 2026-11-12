package diff

import "example.com/diff/internal/myers"

// Diff returns a minimal edit script that turns a into b. Lines are compared
// byte for byte. Among the minimal scripts, the one returned is unspecified.
//
// Running time is O((N+M)·D) for D the cost of the script, using O(N+M)
// additional space.
func Diff(a, b []string) Script {
	ia, ib := Intern(a, b)
	deleted, inserted := myers.Compare(ia, ib)

	s := make(Script, 0, len(a)+len(b))
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		switch {
		case i < len(a) && deleted[i]:
			s = append(s, Edit{Delete, a[i]})
			i++
		case j < len(b) && inserted[j]:
			s = append(s, Edit{Insert, b[j]})
			j++
		default:
			// Neither line is marked, so they are matched to each other.
			s = append(s, Edit{Keep, a[i]})
			i++
			j++
		}
	}
	return s
}

// Intern maps every distinct line of a and b to a small integer so that two
// lines are equal exactly when their ids are equal.
func Intern(a, b []string) (ia, ib []int32) {
	ids := make(map[string]int32, len(a)+len(b))
	conv := func(lines []string) []int32 {
		out := make([]int32, len(lines))
		for i, l := range lines {
			id, ok := ids[l]
			if !ok {
				id = int32(len(ids))
				ids[l] = id
			}
			out[i] = id
		}
		return out
	}
	return conv(a), conv(b)
}
