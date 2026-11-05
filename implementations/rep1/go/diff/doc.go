// Package linediff computes shortest line-oriented edit scripts (diffs) and
// applies them (patch).
//
// The diff is exact: it always returns a script with the minimum possible
// number of deletions plus insertions. It is built on Myers' O(ND) algorithm
// in its linear-space "middle snake" form (E. Myers, "An O(ND) Difference
// Algorithm and Its Variations", 1986), after interning lines to integer ids
// and trimming common prefixes and suffixes.
//
// The package is organised by responsibility:
//
//   - lines.go:  splitting text into line views.
//   - intern.go: mapping lines to dense integer ids.
//   - myers.go:  the linear-space Myers search over integer sequences.
//   - diff.go:   the public Diff entry points and the Op type.
//   - script.go: rendering and parsing the textual edit-script format.
//   - patch.go:  applying a parsed script to a file.
//
// Lines are plain []byte values without their line terminator; two lines are
// equal when they are byte-for-byte identical.
package linediff
