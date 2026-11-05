package cube

import (
	"fmt"
	"strings"
)

// Face identifies one of the six faces of the cube.
type Face uint8

// The faces, in the order used throughout the library.
const (
	U Face = iota
	R
	F
	D
	L
	B
	NumFaces = 6
)

// String returns the single-letter name of the face.
func (f Face) String() string {
	if f >= NumFaces {
		return "?"
	}
	return "URFDLB"[f : f+1]
}

// Opposite returns the face on the other side of the cube.
func (f Face) Opposite() Face { return (f + 3) % NumFaces }

// Move is one of the eighteen face turns. A Move is Face*3 + (turns-1),
// where turns is 1 (clockwise quarter turn), 2 (half turn) or 3
// (counter-clockwise quarter turn).
type Move uint8

// NumMoves is the number of distinct moves.
const NumMoves = 18

// NewMove builds the move that turns face f clockwise by the given number of
// quarter turns, which must be 1, 2 or 3.
func NewMove(f Face, quarterTurns int) Move {
	if f >= NumFaces || quarterTurns < 1 || quarterTurns > 3 {
		panic("cube: invalid move")
	}
	return Move(int(f)*3 + quarterTurns - 1)
}

// Face returns the face the move turns.
func (m Move) Face() Face { return Face(m / 3) }

// Turns returns the number of clockwise quarter turns: 1, 2 or 3.
func (m Move) Turns() int { return int(m%3) + 1 }

// Inverse returns the move that undoes m.
func (m Move) Inverse() Move { return NewMove(m.Face(), 4-m.Turns()) }

// IsHalfTurn reports whether m is a half turn (X2).
func (m Move) IsHalfTurn() bool { return m%3 == 1 }

// String returns the move in standard notation: "R", "R2" or "R'".
func (m Move) String() string {
	if m >= NumMoves {
		return "?"
	}
	return moveNames[m]
}

var moveNames = func() (names [NumMoves]string) {
	suffix := [3]string{"", "2", "'"}
	for m := range names {
		names[m] = Face(m/3).String() + suffix[m%3]
	}
	return
}()

// ParseMove parses a single move token such as "U", "D'" or "F2".
func ParseMove(tok string) (Move, error) {
	if len(tok) < 1 || len(tok) > 2 {
		return 0, fmt.Errorf("cube: invalid move %q", tok)
	}
	f := strings.IndexByte("URFDLB", tok[0])
	if f < 0 {
		return 0, fmt.Errorf("cube: invalid move %q", tok)
	}
	if len(tok) == 1 {
		return NewMove(Face(f), 1), nil
	}
	switch tok[1] {
	case '2':
		return NewMove(Face(f), 2), nil
	case '\'':
		return NewMove(Face(f), 3), nil
	}
	return 0, fmt.Errorf("cube: invalid move %q", tok)
}

// ParseMoves parses a whitespace-separated sequence of move tokens. The
// empty string yields an empty sequence.
func ParseMoves(s string) ([]Move, error) {
	fields := strings.Fields(s)
	moves := make([]Move, 0, len(fields))
	for _, tok := range fields {
		m, err := ParseMove(tok)
		if err != nil {
			return nil, err
		}
		moves = append(moves, m)
	}
	return moves, nil
}

// FormatMoves renders moves in standard notation separated by single spaces.
func FormatMoves(moves []Move) string {
	return string(AppendMoves(nil, moves))
}

// AppendMoves appends the notation for moves, separated by single spaces, to
// dst and returns the extended slice.
func AppendMoves(dst []byte, moves []Move) []byte {
	for i, m := range moves {
		if i > 0 {
			dst = append(dst, ' ')
		}
		dst = append(dst, m.String()...)
	}
	return dst
}

// InverseMoves returns the sequence that undoes moves.
func InverseMoves(moves []Move) []Move {
	inv := make([]Move, len(moves))
	for i, m := range moves {
		inv[len(moves)-1-i] = m.Inverse()
	}
	return inv
}

// Simplify merges consecutive turns of the same face (for example "R R" into
// "R2" and "R R'" into nothing) and returns the shortened sequence. The
// input is not modified.
func Simplify(moves []Move) []Move {
	out := make([]Move, 0, len(moves))
	for _, m := range moves {
		if n := len(out); n > 0 && out[n-1].Face() == m.Face() {
			total := (out[n-1].Turns() + m.Turns()) % 4
			out = out[:n-1]
			if total != 0 {
				out = append(out, NewMove(m.Face(), total))
			}
			continue
		}
		out = append(out, m)
	}
	return out
}
