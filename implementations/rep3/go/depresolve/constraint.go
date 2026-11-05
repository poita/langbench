package depresolve

import (
	"fmt"
	"strings"
)

// A Range is a version constraint. Whatever its source syntax, it is reduced
// to one half-open interval [lo, hi) of packed version keys, so testing a
// version is two integer comparisons. The zero Range accepts nothing; use
// AnyVersion or ParseRange to obtain useful values.
type Range struct {
	lo, hi uint64
}

// AnyVersion is the range "*": it accepts every version.
var AnyVersion = Range{0, keyInf}

// ParseRange parses the range syntax of the registry format:
//
//   - every version
//     X.Y.Z                 exactly X.Y.Z
//     ^X.Y.Z                npm caret: leftmost non-zero component fixed
//     ~X.Y.Z                npm tilde: major and minor fixed
//     <A  <=A  >A  >=A      one to three comparators separated by single
//     spaces; all of them must hold
func ParseRange(s string) (Range, error) {
	switch {
	case s == "*":
		return AnyVersion, nil
	case s == "":
		return Range{}, fmt.Errorf("empty range")
	case s[0] == '^' || s[0] == '~':
		v, err := ParseVersion(s[1:])
		if err != nil {
			return Range{}, fmt.Errorf("invalid range %q: %w", s, err)
		}
		if s[0] == '~' {
			return Tilde(v), nil
		}
		return Caret(v), nil
	case s[0] >= '0' && s[0] <= '9':
		v, err := ParseVersion(s)
		if err != nil {
			return Range{}, fmt.Errorf("invalid range %q: %w", s, err)
		}
		return Exact(v), nil
	}
	r := AnyVersion
	n := 0
	for rest := s; ; n++ {
		tok := rest
		more := false
		if i := strings.IndexByte(rest, ' '); i >= 0 {
			tok, rest, more = rest[:i], rest[i+1:], true
		}
		op, vs := splitOp(tok)
		if op == "" {
			return Range{}, fmt.Errorf("invalid range %q: bad comparator %q", s, tok)
		}
		v, err := ParseVersion(vs)
		if err != nil {
			return Range{}, fmt.Errorf("invalid range %q: %w", s, err)
		}
		k := v.key()
		switch op {
		case "<":
			r.hi = min(r.hi, k)
		case "<=":
			r.hi = min(r.hi, k+1)
		case ">":
			r.lo = max(r.lo, k+1)
		case ">=":
			r.lo = max(r.lo, k)
		}
		if !more {
			break
		}
	}
	if n >= 3 {
		return Range{}, fmt.Errorf("invalid range %q: more than three comparators", s)
	}
	return r, nil
}

func splitOp(tok string) (op, rest string) {
	switch {
	case strings.HasPrefix(tok, "<="), strings.HasPrefix(tok, ">="):
		return tok[:2], tok[2:]
	case strings.HasPrefix(tok, "<"), strings.HasPrefix(tok, ">"):
		return tok[:1], tok[1:]
	}
	return "", tok
}

// Exact returns the range that accepts only v.
func Exact(v Version) Range {
	k := v.key()
	return Range{k, k + 1}
}

// Caret returns the npm caret range ^v: it keeps the leftmost non-zero
// component of v fixed (^1.2.3 is >=1.2.3 <2.0.0, ^0.2.3 is >=0.2.3 <0.3.0
// and ^0.0.3 accepts only 0.0.3).
func Caret(v Version) Range {
	maj, mnr, pat := uint64(v.Major), uint64(v.Minor), uint64(v.Patch)
	switch {
	case maj > 0:
		return Range{v.key(), packKey(maj+1, 0, 0)}
	case mnr > 0:
		return Range{v.key(), packKey(0, mnr+1, 0)}
	}
	return Range{v.key(), packKey(0, 0, pat+1)}
}

// Tilde returns the npm tilde range ~v: major and minor stay fixed
// (~1.2.3 is >=1.2.3 <1.3.0, ~0.0.3 is >=0.0.3 <0.1.0).
func Tilde(v Version) Range {
	return Range{v.key(), packKey(uint64(v.Major), uint64(v.Minor)+1, 0)}
}

// Empty reports whether no version at all satisfies r.
func (r Range) Empty() bool { return r.lo >= r.hi }

// Contains reports whether v satisfies r.
func (r Range) Contains(v Version) bool {
	k := v.key()
	return r.lo <= k && k < r.hi
}
