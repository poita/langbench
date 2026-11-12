package depresolve

import (
	"fmt"
	"strings"
)

// Range is a set of versions described by one of the range forms:
//
//   - every version
//     X.Y.Z                  exactly X.Y.Z
//     ^X.Y.Z                 npm caret: leftmost non-zero component fixed
//     ~X.Y.Z                 npm tilde: major and minor fixed
//     <A <=A >A >=A          one to three comparators separated by spaces,
//     all of which must hold
//
// Every range denotes a half-open interval [lo, hi) of versions (hi may be
// unbounded), so Range is a small comparable value type. The zero Range is
// empty; use ParseRange or Any to obtain useful ranges.
type Range struct {
	lo    Version
	hi    Version
	hiInf bool
	text  string
}

// Any returns the range "*" that accepts every version.
func Any() Range { return Range{hiInf: true, text: "*"} }

// String returns the textual form the range was parsed from.
func (r Range) String() string {
	if r.text == "" {
		return "<0.0.0"
	}
	return r.text
}

// Contains reports whether v lies in the range.
func (r Range) Contains(v Version) bool {
	if v.Less(r.lo) {
		return false
	}
	return r.hiInf || v.Less(r.hi)
}

// Empty reports whether no version satisfies the range.
func (r Range) Empty() bool {
	return !r.hiInf && r.hi.Compare(r.lo) <= 0
}

// ParseRange parses a range expression; see Range for the grammar.
func ParseRange(s string) (Range, error) {
	switch {
	case s == "*":
		return Any(), nil
	case s == "":
		return Range{}, fmt.Errorf("empty range")
	case s[0] == '^' || s[0] == '~':
		v, err := ParseVersion(s[1:])
		if err != nil {
			return Range{}, fmt.Errorf("invalid range %q: %v", s, err)
		}
		hi := Version{v.Major + 1, 0, 0}
		switch {
		case s[0] == '~':
			hi = Version{v.Major, v.Minor + 1, 0}
		case v.Major > 0:
		case v.Minor > 0:
			hi = Version{0, v.Minor + 1, 0}
		default:
			hi = v.next()
		}
		return Range{lo: v, hi: hi, text: s}, nil
	case s[0] >= '0' && s[0] <= '9':
		v, err := ParseVersion(s)
		if err != nil {
			return Range{}, fmt.Errorf("invalid range %q: %v", s, err)
		}
		return Range{lo: v, hi: v.next(), text: s}, nil
	}
	// Comparator list.
	r := Range{hiInf: true, text: s}
	for _, c := range strings.Split(s, " ") {
		var op string
		switch {
		case strings.HasPrefix(c, "<="), strings.HasPrefix(c, ">="):
			op = c[:2]
		case strings.HasPrefix(c, "<"), strings.HasPrefix(c, ">"):
			op = c[:1]
		default:
			return Range{}, fmt.Errorf("invalid range %q: bad comparator %q", s, c)
		}
		v, err := ParseVersion(c[len(op):])
		if err != nil {
			return Range{}, fmt.Errorf("invalid range %q: %v", s, err)
		}
		switch op {
		case ">=":
			r.raiseLo(v)
		case ">":
			r.raiseLo(v.next())
		case "<":
			r.lowerHi(v)
		case "<=":
			r.lowerHi(v.next())
		}
	}
	return r, nil
}

func (r *Range) raiseLo(v Version) {
	if r.lo.Less(v) {
		r.lo = v
	}
}

func (r *Range) lowerHi(v Version) {
	if r.hiInf || v.Less(r.hi) {
		r.hi, r.hiInf = v, false
	}
}
