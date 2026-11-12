package qrcode

import (
	"errors"
	"fmt"
	"strings"
)

// AutoMask requests that Encode choose the mask with the lowest penalty score.
const AutoMask = -1

// ErrTooLong is returned when the data does not fit in any version at the
// requested error-correction level.
var ErrTooLong = errors.New("qrcode: data too long for any version at this error-correction level")

// Symbol is an encoded QR Code symbol.
type Symbol struct {
	version int
	level   Level
	mask    int
	grid    *grid
}

// Version returns the symbol version (1..40).
func (s *Symbol) Version() int { return s.version }

// Level returns the error-correction level.
func (s *Symbol) Level() Level { return s.level }

// Mask returns the mask pattern (0..7) applied to the symbol.
func (s *Symbol) Mask() int { return s.mask }

// Size returns the side length of the symbol in modules (4*version + 17).
func (s *Symbol) Size() int { return s.grid.n }

// Dark reports whether the module at column x, row y (0-based from the
// top-left) is dark. Coordinates outside the symbol are light.
func (s *Symbol) Dark(x, y int) bool {
	n := s.grid.n
	if x < 0 || y < 0 || x >= n || y >= n {
		return false
	}
	return s.grid.modules[y*n+x]
}

// String renders the symbol as Size() lines of '#' (dark) and '.' (light),
// each terminated by a newline. No quiet zone is included.
func (s *Symbol) String() string {
	n := s.grid.n
	var sb strings.Builder
	sb.Grow(n * (n + 1))
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			if s.grid.modules[y*n+x] {
				sb.WriteByte('#')
			} else {
				sb.WriteByte('.')
			}
		}
		sb.WriteByte('\n')
	}
	return sb.String()
}

// Encode encodes text at the given error-correction level. mask is a pattern
// number 0..7 or AutoMask. The text is treated as its UTF-8 bytes.
func Encode(text string, level Level, mask int) (*Symbol, error) {
	return EncodeBytes([]byte(text), level, mask)
}

// EncodeBytes is like Encode for a byte slice.
//
// The most compact single mode (numeric, alphanumeric, byte) is selected and
// the smallest version that holds the data is used. No ECI header is written.
func EncodeBytes(data []byte, level Level, mask int) (*Symbol, error) {
	if level < L || level > H {
		return nil, fmt.Errorf("qrcode: invalid error-correction level %d", int(level))
	}
	if mask < AutoMask || mask >= NumMasks {
		return nil, fmt.Errorf("qrcode: invalid mask %d", mask)
	}
	mode := SelectMode(data)
	version := chooseVersion(mode, len(data), level)
	if version == 0 {
		return nil, ErrTooLong
	}

	bb := encodeSegment(data, mode, version)
	dataCW := padDataCodewords(bb, dataCodewords(version, level))
	codewords := addECCAndInterleave(dataCW, version, level)

	base := newFunctionGrid(version)
	base.placeData(codewords)

	finish := func(m int) *grid {
		g := base.clone()
		g.applyMask(m)
		g.drawFormat(level, m)
		return g
	}

	var best *grid
	if mask != AutoMask {
		best = finish(mask)
	} else {
		bestScore := 0
		for m := 0; m < NumMasks; m++ {
			g := finish(m)
			if p := g.penalty(); best == nil || p < bestScore {
				best, bestScore, mask = g, p, m
			}
		}
	}
	return &Symbol{version: version, level: level, mask: mask, grid: best}, nil
}
