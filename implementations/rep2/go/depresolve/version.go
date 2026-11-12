package depresolve

import (
	"fmt"
	"strconv"
	"strings"
)

// MaxComponent is the largest value accepted for a version component. It
// keeps the arithmetic used to turn ranges into half-open intervals free of
// overflow.
const MaxComponent = 1<<31 - 1

// Version is a semantic version without prerelease or build metadata.
type Version struct {
	Major, Minor, Patch uint32
}

// Compare returns -1, 0 or +1 according to whether v is older than, equal
// to or newer than w. Components are compared numerically, major first.
func (v Version) Compare(w Version) int {
	switch {
	case v.Major != w.Major:
		return cmp3(v.Major, w.Major)
	case v.Minor != w.Minor:
		return cmp3(v.Minor, w.Minor)
	default:
		return cmp3(v.Patch, w.Patch)
	}
}

func cmp3(a, b uint32) int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

// Less reports whether v is older than w.
func (v Version) Less(w Version) bool { return v.Compare(w) < 0 }

// String formats v as MAJOR.MINOR.PATCH.
func (v Version) String() string {
	return strconv.FormatUint(uint64(v.Major), 10) + "." +
		strconv.FormatUint(uint64(v.Minor), 10) + "." +
		strconv.FormatUint(uint64(v.Patch), 10)
}

// next returns the smallest version strictly greater than v.
func (v Version) next() Version { return Version{v.Major, v.Minor, v.Patch + 1} }

// ParseVersion parses "MAJOR.MINOR.PATCH": three decimal integers without
// leading zeros, each at most MaxComponent.
func ParseVersion(s string) (Version, error) {
	parts := strings.Split(s, ".")
	if len(parts) != 3 {
		return Version{}, fmt.Errorf("invalid version %q: want MAJOR.MINOR.PATCH", s)
	}
	var c [3]uint32
	for i, p := range parts {
		n, err := parseNum(p)
		if err != nil {
			return Version{}, fmt.Errorf("invalid version %q: %v", s, err)
		}
		c[i] = n
	}
	return Version{c[0], c[1], c[2]}, nil
}

// MustParseVersion is like ParseVersion but panics on error. It is meant for
// literals in tests and examples.
func MustParseVersion(s string) Version {
	v, err := ParseVersion(s)
	if err != nil {
		panic(err)
	}
	return v
}

func parseNum(s string) (uint32, error) {
	if s == "" {
		return 0, fmt.Errorf("empty number")
	}
	if len(s) > 1 && s[0] == '0' {
		return 0, fmt.Errorf("leading zero in %q", s)
	}
	var n uint64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("bad digit in %q", s)
		}
		n = n*10 + uint64(c-'0')
		if n > MaxComponent {
			return 0, fmt.Errorf("number %q too large", s)
		}
	}
	return uint32(n), nil
}
