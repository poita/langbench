package depresolve

import (
	"fmt"
	"math"
	"strings"
)

// Range is a version constraint, normalised to a half-open interval
// [Lo, Hi) of packed version keys (see Version.Key). Every supported range
// syntax (*, exact, ^, ~ and comparator lists) is a single interval.
type Range struct {
	Lo, Hi uint64
}

// AnyVersion is the range "*".
var AnyVersion = Range{Lo: 0, Hi: math.MaxUint64}

// Contains reports whether v satisfies the range.
func (r Range) Contains(v Version) bool { return r.ContainsKey(v.Key()) }

// ContainsKey reports whether the packed version key k satisfies the range.
func (r Range) ContainsKey(k uint64) bool { return r.Lo <= k && k < r.Hi }

// Empty reports whether no version can satisfy the range.
func (r Range) Empty() bool { return r.Lo >= r.Hi }

// ParseRange parses the range grammar:
//
//   - any version
//     X.Y.Z        exactly that version
//     ^X.Y.Z       npm caret: keep the leftmost non-zero component fixed
//     ~X.Y.Z       npm tilde: keep major and minor fixed
//     <A <=A >A >=A  one to three space-separated comparators, all must hold
func ParseRange(s string) (Range, error) {
	if s == "" {
		return Range{}, fmt.Errorf("empty range")
	}
	switch s[0] {
	case '*':
		if s != "*" {
			return Range{}, fmt.Errorf("invalid range %q", s)
		}
		return AnyVersion, nil
	case '^', '~':
		v, err := ParseVersion(s[1:])
		if err != nil {
			return Range{}, err
		}
		if s[0] == '~' {
			return Range{v.Key(), Version{v.Major, v.Minor + 1, 0}.Key()}, nil
		}
		switch {
		case v.Major > 0:
			return Range{v.Key(), Version{v.Major + 1, 0, 0}.Key()}, nil
		case v.Minor > 0:
			return Range{v.Key(), Version{0, v.Minor + 1, 0}.Key()}, nil
		}
		return Range{v.Key(), Version{0, 0, v.Patch + 1}.Key()}, nil
	case '<', '>':
		return parseComparators(s)
	}
	v, err := ParseVersion(s)
	if err != nil {
		return Range{}, err
	}
	return Range{v.Key(), v.Key() + 1}, nil
}

func parseComparators(s string) (Range, error) {
	r := AnyVersion
	for _, c := range strings.Split(s, " ") {
		n := 1
		if len(c) > 1 && c[1] == '=' {
			n = 2
		}
		if len(c) < n+1 || (c[0] != '<' && c[0] != '>') {
			return Range{}, fmt.Errorf("invalid comparator %q", c)
		}
		op := c[:n]
		v, err := ParseVersion(c[n:])
		if err != nil {
			return Range{}, err
		}
		k := v.Key()
		switch op {
		case "<":
			r.Hi = min(r.Hi, k)
		case "<=":
			r.Hi = min(r.Hi, k+1)
		case ">":
			r.Lo = max(r.Lo, k+1)
		case ">=":
			r.Lo = max(r.Lo, k)
		}
	}
	return r, nil
}

// Requirement is a dependency: a package name and the versions acceptable.
type Requirement struct {
	Name  string
	Range Range
}
