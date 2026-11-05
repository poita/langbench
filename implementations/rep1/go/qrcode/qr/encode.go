package qr

import (
	"errors"
	"fmt"
	"strconv"
)

// AutoMask requests automatic mask selection by penalty scoring.
const AutoMask = -1

// Errors returned by Encode.
var (
	ErrEmpty   = errors.New("qr: empty input")
	ErrTooLong = errors.New("qr: data does not fit in any version at this error correction level")
	ErrBadECL  = errors.New("qr: invalid error correction level")
	ErrBadMask = errors.New("qr: mask must be 0..7 or AutoMask")
)

// Symbol is an encoded QR code.
type Symbol struct {
	Version int // 1..40
	Mask    int // 0..7, the mask actually used
	ECL     ECL
	Mode    Mode
	size    int
	mod     []byte
}

// Size returns the side length of the symbol in modules (4*Version+17).
func (s *Symbol) Size() int { return s.size }

// Dark reports whether the module in column x, row y is dark. Coordinates
// outside the symbol are light.
func (s *Symbol) Dark(x, y int) bool {
	if x < 0 || y < 0 || x >= s.size || y >= s.size {
		return false
	}
	return s.mod[y*s.size+x] != 0
}

// AppendRows appends the symbol to dst, one line per row terminated by '\n',
// using '#' for dark and '.' for light modules, and returns the result.
func (s *Symbol) AppendRows(dst []byte) []byte {
	n := s.size
	for y := 0; y < n; y++ {
		for _, c := range s.mod[y*n : y*n+n] {
			dst = append(dst, ".#"[c])
		}
		dst = append(dst, '\n')
	}
	return dst
}

// String renders the rows as by AppendRows.
func (s *Symbol) String() string {
	return string(s.AppendRows(make([]byte, 0, s.size*(s.size+1))))
}

// Encode encodes data as a QR Code symbol at error correction level ecl.
// The mode (numeric, alphanumeric or byte) and the smallest sufficient
// version are chosen automatically. mask is 0..7 to force a mask pattern, or
// AutoMask to pick the one with the lowest penalty (lowest number on ties).
func Encode(data []byte, ecl ECL, mask int) (*Symbol, error) {
	if len(data) == 0 {
		return nil, ErrEmpty
	}
	if ecl < L || ecl > H {
		return nil, ErrBadECL
	}
	if mask < AutoMask || mask > 7 {
		return nil, ErrBadMask
	}
	mode := SelectMode(data)
	v := chooseVersion(mode, len(data), ecl)
	if v == 0 {
		return nil, ErrTooLong
	}
	cw := addECCAndInterleave(buildDataCodewords(data, mode, v, ecl), v, ecl)
	b := newBase(v, cw)

	n := b.n
	cur := newGrid(n)
	if mask != AutoMask {
		b.render(&cur, ecl, mask)
	} else {
		best := newGrid(n)
		bestScore := -1
		for m := 0; m < 8; m++ {
			b.render(&cur, ecl, m)
			if s := penalty(&cur); bestScore < 0 || s < bestScore {
				bestScore, mask = s, m
				cur, best = best, cur
			}
		}
		cur = best
	}
	return &Symbol{Version: v, Mask: mask, ECL: ecl, Mode: mode, size: n, mod: cur.mod}, nil
}

// EncodeString is Encode for a string payload (its UTF-8 bytes).
func EncodeString(text string, ecl ECL, mask int) (*Symbol, error) {
	return Encode([]byte(text), ecl, mask)
}

// ParseMask converts "0".."7" or "auto" to a mask value for Encode.
func ParseMask(s string) (int, error) {
	if s == "auto" {
		return AutoMask, nil
	}
	if len(s) == 1 && s[0] >= '0' && s[0] <= '7' {
		return int(s[0] - '0'), nil
	}
	return 0, fmt.Errorf("qr: invalid mask %s", strconv.Quote(s))
}
