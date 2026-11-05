package depresolve

import (
	"fmt"
	"strconv"
	"strings"
)

// MaxComponent is the largest value accepted for a version component.
const MaxComponent = 1000000

// Key is a Version packed into one integer that orders like the version
// itself. Components use 21 bits each, so keys of the exclusive bounds that
// ranges produce (a component of MaxComponent+1) still order correctly.
type Key uint64

const (
	componentBits = 21
	componentMask = 1<<componentBits - 1
	// maxKey is above every key a real version can have.
	maxKey = Key(^uint64(0))
)

// Version is a semantic version MAJOR.MINOR.PATCH (no prerelease or build
// suffixes).
type Version struct {
	Major, Minor, Patch uint32
}

// ParseVersion parses "MAJOR.MINOR.PATCH". Each component must be a decimal
// integer without leading zeros and at most MaxComponent.
func ParseVersion(s string) (Version, error) {
	var parts [3]uint32
	rest := s
	for i := 0; i < 3; i++ {
		var field string
		if i < 2 {
			j := strings.IndexByte(rest, '.')
			if j < 0 {
				return Version{}, fmt.Errorf("invalid version %q: want MAJOR.MINOR.PATCH", s)
			}
			field, rest = rest[:j], rest[j+1:]
		} else {
			field = rest
		}
		n, err := parseComponent(field)
		if err != nil {
			return Version{}, fmt.Errorf("invalid version %q: %w", s, err)
		}
		parts[i] = n
	}
	return Version{parts[0], parts[1], parts[2]}, nil
}

func parseComponent(f string) (uint32, error) {
	if f == "" {
		return 0, fmt.Errorf("empty component")
	}
	if len(f) > 1 && f[0] == '0' {
		return 0, fmt.Errorf("component %q has a leading zero", f)
	}
	for i := 0; i < len(f); i++ {
		if f[i] < '0' || f[i] > '9' {
			return 0, fmt.Errorf("component %q is not a number", f)
		}
	}
	n, err := strconv.ParseUint(f, 10, 32)
	if err != nil || n > MaxComponent {
		return 0, fmt.Errorf("component %q out of range (max %d)", f, MaxComponent)
	}
	return uint32(n), nil
}

// MustParseVersion is like ParseVersion but panics on error. It is intended
// for tests and constants.
func MustParseVersion(s string) Version {
	v, err := ParseVersion(s)
	if err != nil {
		panic(err)
	}
	return v
}

// Key returns the packed integer key of v.
func (v Version) Key() Key {
	return makeKey(uint64(v.Major), uint64(v.Minor), uint64(v.Patch))
}

func makeKey(major, minor, patch uint64) Key {
	return Key(major<<(2*componentBits) | minor<<componentBits | patch)
}

// Compare returns -1, 0 or +1 as v is older than, equal to or newer than w,
// comparing components numerically.
func (v Version) Compare(w Version) int {
	a, b := v.Key(), w.Key()
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// String formats v as "MAJOR.MINOR.PATCH".
func (v Version) String() string {
	return string(v.appendTo(nil))
}

func (v Version) appendTo(b []byte) []byte {
	b = strconv.AppendUint(b, uint64(v.Major), 10)
	b = append(b, '.')
	b = strconv.AppendUint(b, uint64(v.Minor), 10)
	b = append(b, '.')
	return strconv.AppendUint(b, uint64(v.Patch), 10)
}
