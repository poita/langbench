package depresolve

import (
	"fmt"
	"strconv"
	"strings"
)

// Version is a semantic version MAJOR.MINOR.PATCH. Prerelease and build
// suffixes are not supported.
type Version struct {
	Major, Minor, Patch uint32
}

// maxComponent is the largest component value the packed key can order
// correctly, including the exclusive bounds ranges produce (component+1).
const maxComponent = 1<<21 - 2

// Key packs the version into a single integer that orders exactly like the
// version does (21 bits per component). It is used for all comparisons.
func (v Version) Key() uint64 {
	return uint64(v.Major)<<42 | uint64(v.Minor)<<21 | uint64(v.Patch)
}

// VersionFromKey is the inverse of Version.Key.
func VersionFromKey(k uint64) Version {
	const m = 1<<21 - 1
	return Version{Major: uint32(k >> 42 & m), Minor: uint32(k >> 21 & m), Patch: uint32(k & m)}
}

// Compare returns -1, 0 or +1 as v is older than, equal to, or newer than w.
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

// String formats the version as MAJOR.MINOR.PATCH.
func (v Version) String() string {
	return strconv.FormatUint(uint64(v.Major), 10) + "." +
		strconv.FormatUint(uint64(v.Minor), 10) + "." +
		strconv.FormatUint(uint64(v.Patch), 10)
}

// ParseVersion parses "MAJOR.MINOR.PATCH". Components are non-negative
// decimal integers without leading zeros, each at most 1,000,000.
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

func parseNum(p string) (uint32, error) {
	if p == "" {
		return 0, fmt.Errorf("empty component")
	}
	if len(p) > 1 && p[0] == '0' {
		return 0, fmt.Errorf("leading zero in component %q", p)
	}
	var n uint64
	for i := 0; i < len(p); i++ {
		d := p[i]
		if d < '0' || d > '9' {
			return 0, fmt.Errorf("non-digit in component %q", p)
		}
		n = n*10 + uint64(d-'0')
		if n > maxComponent {
			return 0, fmt.Errorf("component %q too large", p)
		}
	}
	return uint32(n), nil
}
