package semver

import (
	"fmt"
	"strings"
)

// Range is a set of versions expressed as a half-open interval [Lo, Hi).
// If Unbounded is true there is no upper bound and Hi is ignored. Every
// supported range syntax (including conjunctions of comparators) denotes such
// an interval, which is what makes candidate lookup a binary search.
type Range struct {
	Lo        Version
	Hi        Version
	Unbounded bool
}

// Any is the range accepting every version ("*").
var Any = Range{Unbounded: true}

// ParseRange parses a range:
//
//   - any version
//     X.Y.Z                 exactly that version
//     ^X.Y.Z                compatible with (npm caret semantics)
//     ~X.Y.Z                same major and minor (npm tilde semantics)
//     <A, <=A, >A, >=A      one to several comparators separated by spaces,
//     all of which must hold
func ParseRange(s string) (Range, error) {
	if s == "" {
		return Range{}, fmt.Errorf("semver: empty range")
	}
	switch s[0] {
	case '*':
		if s != "*" {
			return Range{}, fmt.Errorf("semver: invalid range %q", s)
		}
		return Any, nil
	case '^':
		v, err := ParseVersion(s[1:])
		if err != nil {
			return Range{}, err
		}
		return Caret(v), nil
	case '~':
		v, err := ParseVersion(s[1:])
		if err != nil {
			return Range{}, err
		}
		return Tilde(v), nil
	case '<', '>':
		r := Any
		for _, c := range strings.Split(s, " ") {
			cr, err := parseComparator(c)
			if err != nil {
				return Range{}, err
			}
			r = r.Intersect(cr)
		}
		return r, nil
	default:
		v, err := ParseVersion(s)
		if err != nil {
			return Range{}, err
		}
		return Exact(v), nil
	}
}

func parseComparator(c string) (Range, error) {
	var op string
	switch {
	case strings.HasPrefix(c, "<="), strings.HasPrefix(c, ">="):
		op = c[:2]
	case strings.HasPrefix(c, "<"), strings.HasPrefix(c, ">"):
		op = c[:1]
	default:
		return Range{}, fmt.Errorf("semver: invalid comparator %q", c)
	}
	v, err := ParseVersion(c[len(op):])
	if err != nil {
		return Range{}, err
	}
	switch op {
	case "<":
		return Range{Hi: v}, nil
	case "<=":
		return Range{Hi: nextPatch(v)}, nil
	case ">":
		return Range{Lo: nextPatch(v), Unbounded: true}, nil
	default: // ">="
		return Range{Lo: v, Unbounded: true}, nil
	}
}

func nextPatch(v Version) Version { return Version{v.Major, v.Minor, v.Patch + 1} }

// Exact returns the range accepting only v.
func Exact(v Version) Range { return Range{Lo: v, Hi: nextPatch(v)} }

// Caret returns the npm caret range for v: the leftmost non-zero component
// is held fixed.
func Caret(v Version) Range {
	switch {
	case v.Major > 0:
		return Range{Lo: v, Hi: Version{v.Major + 1, 0, 0}}
	case v.Minor > 0:
		return Range{Lo: v, Hi: Version{0, v.Minor + 1, 0}}
	default:
		return Range{Lo: v, Hi: Version{0, 0, v.Patch + 1}}
	}
}

// Tilde returns the npm tilde range for v: major and minor are held fixed.
func Tilde(v Version) Range {
	return Range{Lo: v, Hi: Version{v.Major, v.Minor + 1, 0}}
}

// Intersect returns the range accepting the versions accepted by both r and o.
func (r Range) Intersect(o Range) Range {
	out := Range{Lo: r.Lo}
	if o.Lo.Compare(out.Lo) > 0 {
		out.Lo = o.Lo
	}
	switch {
	case r.Unbounded:
		out.Hi, out.Unbounded = o.Hi, o.Unbounded
	case o.Unbounded:
		out.Hi = r.Hi
	case o.Hi.Compare(r.Hi) < 0:
		out.Hi = o.Hi
	default:
		out.Hi = r.Hi
	}
	return out
}

// Contains reports whether v lies in the range.
func (r Range) Contains(v Version) bool {
	if v.Compare(r.Lo) < 0 {
		return false
	}
	return r.Unbounded || v.Compare(r.Hi) < 0
}

// Empty reports whether no version satisfies the range.
func (r Range) Empty() bool {
	return !r.Unbounded && r.Hi.Compare(r.Lo) <= 0
}

// String renders the range in a canonical interval form such as
// ">=1.2.0 <2.0.0" (or "*" for the unrestricted range). It does not
// necessarily reproduce the syntax the range was parsed from.
func (r Range) String() string {
	zero := Version{}
	switch {
	case r.Unbounded && r.Lo == zero:
		return "*"
	case r.Unbounded:
		return ">=" + r.Lo.String()
	case r.Lo == zero:
		return "<" + r.Hi.String()
	default:
		return ">=" + r.Lo.String() + " <" + r.Hi.String()
	}
}

// MustParseRange is like ParseRange but panics on error.
func MustParseRange(s string) Range {
	r, err := ParseRange(s)
	if err != nil {
		panic(err)
	}
	return r
}
