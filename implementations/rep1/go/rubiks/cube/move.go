package cube

import (
	"fmt"
	"strings"
)

// Face identifies one of the six faces of the cube.
type Face uint8

// The six faces, in the order used throughout the package.
const (
	U Face = iota
	R
	F
	D
	L
	B
)

const faceLetters = "URFDLB"

// String returns the one-letter name of the face.
func (f Face) String() string {
	if f > B {
		return "?"
	}
	return faceLetters[f : f+1]
}

// Move is one of the eighteen face turns. Its value is 3*face + turn, where
// turn 0 is a clockwise quarter turn, 1 a half turn and 2 an anticlockwise
// quarter turn.
type Move uint8

// NumMoves is the number of distinct moves.
const NumMoves = 18

// Move constructors for the eighteen turns.
const (
	MoveU Move = iota
	MoveU2
	MoveUPrime
	MoveR
	MoveR2
	MoveRPrime
	MoveF
	MoveF2
	MoveFPrime
	MoveD
	MoveD2
	MoveDPrime
	MoveL
	MoveL2
	MoveLPrime
	MoveB
	MoveB2
	MoveBPrime
)

// NewMove returns the move that turns face f by turns quarter turns
// clockwise; turns is taken modulo 4 and must not be a multiple of 4.
func NewMove(f Face, turns int) Move {
	t := ((turns % 4) + 4) % 4
	if t == 0 || f > B {
		panic("cube: invalid move")
	}
	return Move(3*int(f) + t - 1)
}

// Face returns the face the move turns.
func (m Move) Face() Face { return Face(m / 3) }

// Turns returns the number of clockwise quarter turns: 1, 2 or 3.
func (m Move) Turns() int { return int(m%3) + 1 }

// Inverse returns the move that undoes m.
func (m Move) Inverse() Move {
	return Move(m/3*3) + (2 - m%3)
}

// String returns the notation of the move: "R", "R2" or "R'".
func (m Move) String() string {
	if m >= NumMoves {
		return "?"
	}
	switch m % 3 {
	case 0:
		return faceLetters[m/3 : m/3+1]
	case 1:
		return faceLetters[m/3:m/3+1] + "2"
	}
	return faceLetters[m/3:m/3+1] + "'"
}

// ParseMove parses a single move token such as "U", "R'" or "F2".
func ParseMove(tok string) (Move, error) {
	if len(tok) < 1 || len(tok) > 2 {
		return 0, fmt.Errorf("cube: invalid move %q", tok)
	}
	f := strings.IndexByte(faceLetters, tok[0])
	if f < 0 {
		return 0, fmt.Errorf("cube: invalid move %q", tok)
	}
	if len(tok) == 1 {
		return Move(3 * f), nil
	}
	switch tok[1] {
	case '2':
		return Move(3*f + 1), nil
	case '\'':
		return Move(3*f + 2), nil
	}
	return 0, fmt.Errorf("cube: invalid move %q", tok)
}

// ParseMoves parses a sequence of move tokens separated by whitespace.
// An empty or blank string yields an empty sequence.
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

// FormatMoves renders a move sequence as space-separated tokens.
func FormatMoves(moves []Move) string {
	return string(AppendMoves(nil, moves))
}

// AppendMoves appends the space-separated notation of moves to dst.
func AppendMoves(dst []byte, moves []Move) []byte {
	for i, m := range moves {
		if i > 0 {
			dst = append(dst, ' ')
		}
		dst = append(dst, faceLetters[m/3])
		switch m % 3 {
		case 1:
			dst = append(dst, '2')
		case 2:
			dst = append(dst, '\'')
		}
	}
	return dst
}

// InvertMoves returns the sequence that undoes moves.
func InvertMoves(moves []Move) []Move {
	inv := make([]Move, len(moves))
	for i, m := range moves {
		inv[len(moves)-1-i] = m.Inverse()
	}
	return inv
}
