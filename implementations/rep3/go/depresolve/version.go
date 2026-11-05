package depresolve

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// MaxComponent is the largest value accepted for any version component.
const MaxComponent = 1_000_000

// A Version is a semantic version MAJOR.MINOR.PATCH without prerelease or
// build suffixes. Components compare numerically, major first.
type Version struct {
	Major, Minor, Patch uint32
}

// Packed keys use 21 bits per component. Components are at most MaxComponent
// and the exclusive bounds produced by ranges reach MaxComponent+1, both of
// which are below 2^21, so a bound never carries into a neighbouring field
// and the packed integers order exactly like the versions they encode.
const (
	compBits = 21
	keyInf   = ^uint64(0) // exclusive upper bound that admits every version
)

func packKey(major, minor, patch uint64) uint64 {
	return major<<(2*compBits) | minor<<compBits | patch
}

// key returns the packed integer that orders like the version.
func (v Version) key() uint64 {
	return packKey(uint64(v.Major), uint64(v.Minor), uint64(v.Patch))
}

func versionFromKey(k uint64) Version {
	const mask = 1<<compBits - 1
	return Version{
		Major: uint32(k >> (2 * compBits) & mask),
		Minor: uint32(k >> compBits & mask),
		Patch: uint32(k & mask),
	}
}

// Compare returns -1, 0 or +1 when v is older than, equal to or newer than w.
func (v Version) Compare(w Version) int {
	a, b := v.key(), w.key()
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// Less reports whether v is older than w.
func (v Version) Less(w Version) bool { return v.key() < w.key() }

// String formats the version as "MAJOR.MINOR.PATCH".
func (v Version) String() string {
	return strconv.FormatUint(uint64(v.Major), 10) + "." +
		strconv.FormatUint(uint64(v.Minor), 10) + "." +
		strconv.FormatUint(uint64(v.Patch), 10)
}

// appendTo appends the textual form of v to b.
func (v Version) appendTo(b []byte) []byte {
	b = strconv.AppendUint(b, uint64(v.Major), 10)
	b = append(b, '.')
	b = strconv.AppendUint(b, uint64(v.Minor), 10)
	b = append(b, '.')
	return strconv.AppendUint(b, uint64(v.Patch), 10)
}

// ParseVersion parses "MAJOR.MINOR.PATCH". Each component is a decimal
// integer without leading zeros and at most MaxComponent.
func ParseVersion(s string) (Version, error) {
	var comp [3]uint32
	rest := s
	for i := 0; i < 3; i++ {
		end := len(rest)
		if i < 2 {
			end = strings.IndexByte(rest, '.')
			if end < 0 {
				return Version{}, fmt.Errorf("invalid version %q: want MAJOR.MINOR.PATCH", s)
			}
		}
		n, err := parseNum(rest[:end])
		if err != nil {
			return Version{}, fmt.Errorf("invalid version %q: %w", s, err)
		}
		comp[i] = n
		if i < 2 {
			rest = rest[end+1:]
		}
	}
	return Version{comp[0], comp[1], comp[2]}, nil
}

var errBadNumber = errors.New("bad number")

// parseNum parses num = "0" | [1-9][0-9]* with the MaxComponent limit.
func parseNum(s string) (uint32, error) {
	if len(s) == 0 || len(s) > 7 || (s[0] == '0' && len(s) > 1) {
		return 0, errBadNumber
	}
	var n uint32
	for i := 0; i < len(s); i++ {
		c := s[i] - '0'
		if c > 9 {
			return 0, errBadNumber
		}
		n = n*10 + uint32(c)
	}
	if n > MaxComponent {
		return 0, errBadNumber
	}
	return n, nil
}
