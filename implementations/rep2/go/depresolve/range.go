package depresolve

import (
	"fmt"
	"strings"
)

// Range is a version range. Whatever its syntax, it is compiled to one
// half-open interval [lo, hi) of version keys, so testing a version costs two
// integer comparisons. The zero Range is empty: nothing satisfies it.
type Range struct {
	lo, hi Key
	text   string
}

// AnyRange returns the range "*", which accepts every version.
func AnyRange() Range { return Range{lo: 0, hi: maxKey, text: "*"} }

// ParseRange parses a range:
//
//   - any version
//     X.Y.Z                  exactly that version
//     ^X.Y.Z                 caret: keeps the leftmost non-zero component fixed
//     ~X.Y.Z                 tilde: keeps major and minor fixed
//     <A  <=A  >A  >=A       one to three comparators separated by single
//     spaces, all of which must hold
//
// Caret and tilde follow npm semantics.
func ParseRange(s string) (Range, error) {
	r, err := parseRange(s)
	if err != nil {
		return Range{}, fmt.Errorf("invalid range %q: %w", s, err)
	}
	r.text = s
	return r, nil
}

// MustParseRange is like ParseRange but panics on error.
func MustParseRange(s string) Range {
	r, err := ParseRange(s)
	if err != nil {
		panic(err)
	}
	return r
}

func parseRange(s string) (Range, error) {
	switch {
	case s == "":
		return Range{}, fmt.Errorf("empty range")
	case s == "*":
		return AnyRange(), nil
	case s[0] == '^' || s[0] == '~':
		v, err := ParseVersion(s[1:])
		if err != nil {
			return Range{}, err
		}
		lo := v.Key()
		major, minor, patch := uint64(v.Major), uint64(v.Minor), uint64(v.Patch)
		switch {
		case s[0] == '~':
			return Range{lo: lo, hi: makeKey(major, minor+1, 0)}, nil
		case major > 0:
			return Range{lo: lo, hi: makeKey(major+1, 0, 0)}, nil
		case minor > 0:
			return Range{lo: lo, hi: makeKey(0, minor+1, 0)}, nil
		default:
			return Range{lo: lo, hi: makeKey(0, 0, patch+1)}, nil
		}
	case s[0] >= '0' && s[0] <= '9':
		v, err := ParseVersion(s)
		if err != nil {
			return Range{}, err
		}
		return Range{lo: v.Key(), hi: v.Key() + 1}, nil
	}
	r := Range{lo: 0, hi: maxKey}
	for _, c := range strings.Split(s, " ") {
		op := c
		var n int
		for n < len(op) && (op[n] == '<' || op[n] == '>' || op[n] == '=') {
			n++
		}
		v, err := ParseVersion(c[n:])
		if err != nil {
			return Range{}, err
		}
		k := v.Key()
		switch c[:n] {
		case "<":
			r.hi = min(r.hi, k)
		case "<=":
			r.hi = min(r.hi, k+1)
		case ">":
			r.lo = max(r.lo, k+1)
		case ">=":
			r.lo = max(r.lo, k)
		default:
			return Range{}, fmt.Errorf("unknown comparator %q", c)
		}
	}
	return r, nil
}

// Contains reports whether v satisfies the range.
func (r Range) Contains(v Version) bool { return r.containsKey(v.Key()) }

func (r Range) containsKey(k Key) bool { return k >= r.lo && k < r.hi }

// Empty reports whether no version can satisfy the range.
func (r Range) Empty() bool { return r.lo >= r.hi }

// String returns the text the range was parsed from ("<empty>" for the zero
// Range).
func (r Range) String() string {
	if r.text == "" {
		return "<empty>"
	}
	return r.text
}
