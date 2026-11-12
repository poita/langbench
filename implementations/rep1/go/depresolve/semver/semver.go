// Package semver implements the tiny subset of semantic versioning that the
// resolver needs: MAJOR.MINOR.PATCH versions (no prerelease or build
// metadata) and the range syntaxes "*", exact, caret, tilde and comparator
// lists, with npm semantics.
package semver

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// Version is a semantic version MAJOR.MINOR.PATCH.
type Version struct {
	Major, Minor, Patch uint32
}

// ParseVersion parses "X.Y.Z" where each component is a decimal integer
// without leading zeros.
func ParseVersion(s string) (Version, error) {
	var parts [3]uint32
	rest := s
	for i := 0; i < 3; i++ {
		end := strings.IndexByte(rest, '.')
		var field string
		if i < 2 {
			if end < 0 {
				return Version{}, fmt.Errorf("semver: invalid version %q", s)
			}
			field, rest = rest[:end], rest[end+1:]
		} else {
			field = rest
		}
		n, err := parseNum(field)
		if err != nil {
			return Version{}, fmt.Errorf("semver: invalid version %q: %w", s, err)
		}
		parts[i] = n
	}
	return Version{parts[0], parts[1], parts[2]}, nil
}

func parseNum(s string) (uint32, error) {
	if s == "" {
		return 0, errors.New("empty component")
	}
	if len(s) > 1 && s[0] == '0' {
		return 0, errors.New("leading zero")
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, errors.New("non-digit in component")
		}
	}
	n, err := strconv.ParseUint(s, 10, 32)
	if err != nil {
		return 0, err
	}
	return uint32(n), nil
}

// MustParseVersion is like ParseVersion but panics on error.
func MustParseVersion(s string) Version {
	v, err := ParseVersion(s)
	if err != nil {
		panic(err)
	}
	return v
}

// Compare returns -1, 0 or +1 as v is older than, equal to, or newer than o.
// Components are compared numerically, major first.
func (v Version) Compare(o Version) int {
	if c := cmp(v.Major, o.Major); c != 0 {
		return c
	}
	if c := cmp(v.Minor, o.Minor); c != 0 {
		return c
	}
	return cmp(v.Patch, o.Patch)
}

func cmp(a, b uint32) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// Less reports whether v is older than o.
func (v Version) Less(o Version) bool { return v.Compare(o) < 0 }

// String returns the version as "X.Y.Z".
func (v Version) String() string {
	return strconv.FormatUint(uint64(v.Major), 10) + "." +
		strconv.FormatUint(uint64(v.Minor), 10) + "." +
		strconv.FormatUint(uint64(v.Patch), 10)
}
