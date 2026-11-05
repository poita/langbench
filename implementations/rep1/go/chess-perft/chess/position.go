package chess

import (
	"fmt"
	"strconv"
	"strings"
)

// StartFEN is the FEN of the standard initial position.
const StartFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

// Position is a chess position stored as bitboards plus a mailbox. Make and
// Unmake mutate it in place.
type Position struct {
	pieces   [6]Bitboard // all pieces of a type, both colours
	colors   [2]Bitboard // all pieces of a colour
	board    [64]Piece   // mailbox
	side     Color
	castling uint8  // CastleWhiteKing | ...
	ep       Square // en passant target square or NoSquare
	halfmove int    // as parsed; carried through FEN() but never updated by Make
	fullmove int    // as parsed; carried through FEN() but never updated by Make
}

// NewPosition returns the standard initial position.
func NewPosition() *Position {
	p, err := ParseFEN(StartFEN)
	if err != nil {
		panic(err) // StartFEN is a constant and valid
	}
	return p
}

func (p *Position) put(pc Piece, s Square) {
	b := s.Bitboard()
	p.pieces[pc.Type()] |= b
	p.colors[pc.Color()] |= b
	p.board[s] = pc
}

func (p *Position) remove(s Square) {
	pc := p.board[s]
	b := s.Bitboard()
	p.pieces[pc.Type()] &^= b
	p.colors[pc.Color()] &^= b
	p.board[s] = NoPiece
}

func (p *Position) movePiece(from, to Square) {
	pc := p.board[from]
	b := from.Bitboard() | to.Bitboard()
	p.pieces[pc.Type()] ^= b
	p.colors[pc.Color()] ^= b
	p.board[from] = NoPiece
	p.board[to] = pc
}

// SideToMove returns the side whose turn it is.
func (p *Position) SideToMove() Color { return p.side }

// PieceAt returns the piece on s, or NoPiece.
func (p *Position) PieceAt(s Square) Piece { return p.board[s] }

// Castling returns the castling rights as a mask of the Castle* constants.
func (p *Position) Castling() uint8 { return p.castling }

// EnPassant returns the en passant target square, or NoSquare.
func (p *Position) EnPassant() Square { return p.ep }

// Occupied returns the set of all occupied squares.
func (p *Position) Occupied() Bitboard { return p.colors[White] | p.colors[Black] }

// Pieces returns the squares holding pieces of the given colour and type.
func (p *Position) Pieces(c Color, t PieceType) Bitboard { return p.pieces[t] & p.colors[c] }

// kingSquare returns the square of c's king.
func (p *Position) kingSquare(c Color) Square { return (p.pieces[King] & p.colors[c]).Lsb() }

// attackedBy reports whether any piece of colour by, other than those in
// removed, attacks s when the board occupancy is occ.
func (p *Position) attackedBy(s Square, by Color, occ, removed Bitboard) bool {
	theirs := p.colors[by] &^ removed
	if pawnAttacks[by.Opponent()][s]&theirs&p.pieces[Pawn] != 0 ||
		knightAttacks[s]&theirs&p.pieces[Knight] != 0 ||
		kingAttacks[s]&theirs&p.pieces[King] != 0 {
		return true
	}
	if diag := theirs & (p.pieces[Bishop] | p.pieces[Queen]); diag != 0 &&
		BishopAttacks(s, occ)&diag != 0 {
		return true
	}
	if orth := theirs & (p.pieces[Rook] | p.pieces[Queen]); orth != 0 &&
		RookAttacks(s, occ)&orth != 0 {
		return true
	}
	return false
}

// IsAttacked reports whether square s is attacked by any piece of colour by.
func (p *Position) IsAttacked(s Square, by Color) bool {
	return p.attackedBy(s, by, p.Occupied(), 0)
}

// InCheck reports whether the side to move is in check.
func (p *Position) InCheck() bool {
	return p.IsAttacked(p.kingSquare(p.side), p.side.Opponent())
}

// ParseFEN parses a FEN record. All six fields are required, but the halfmove
// and fullmove counters are only stored, never used by the move generator.
//
// The position is validated for exactly one king per side, no pawns on the
// first or last rank, castling rights that match the king and rook placement,
// and the side not to move not being in check.
func ParseFEN(fen string) (*Position, error) {
	fields := strings.Fields(fen)
	if len(fields) != 6 {
		return nil, fmt.Errorf("chess: FEN needs 6 fields, got %d", len(fields))
	}
	p := &Position{ep: NoSquare}
	for i := range p.board {
		p.board[i] = NoPiece
	}

	ranks := strings.Split(fields[0], "/")
	if len(ranks) != 8 {
		return nil, fmt.Errorf("chess: FEN placement needs 8 ranks, got %d", len(ranks))
	}
	for i, rs := range ranks {
		rank, file := 7-i, 0
		for _, ch := range rs {
			if ch >= '1' && ch <= '8' {
				file += int(ch - '0')
				continue
			}
			idx := strings.IndexRune(pieceChars, ch)
			if idx < 0 || file > 7 {
				return nil, fmt.Errorf("chess: bad FEN placement %q", fields[0])
			}
			p.put(Piece(idx), MakeSquare(file, rank))
			file++
		}
		if file != 8 {
			return nil, fmt.Errorf("chess: FEN rank %q does not have 8 files", rs)
		}
	}

	switch fields[1] {
	case "w":
		p.side = White
	case "b":
		p.side = Black
	default:
		return nil, fmt.Errorf("chess: bad side to move %q", fields[1])
	}

	if fields[2] != "-" {
		for _, ch := range fields[2] {
			i := strings.IndexRune("KQkq", ch)
			if i < 0 {
				return nil, fmt.Errorf("chess: bad castling field %q", fields[2])
			}
			p.castling |= 1 << i
		}
	}

	if fields[3] != "-" {
		s, err := ParseSquare(fields[3])
		if err != nil {
			return nil, err
		}
		p.ep = s
	}

	var err error
	if p.halfmove, err = strconv.Atoi(fields[4]); err != nil {
		return nil, fmt.Errorf("chess: bad halfmove clock %q", fields[4])
	}
	if p.fullmove, err = strconv.Atoi(fields[5]); err != nil {
		return nil, fmt.Errorf("chess: bad fullmove number %q", fields[5])
	}

	if err := p.validate(); err != nil {
		return nil, err
	}
	return p, nil
}

func (p *Position) validate() error {
	for c := White; c <= Black; c++ {
		if p.Pieces(c, King).Count() != 1 {
			return fmt.Errorf("chess: each side needs exactly one king")
		}
	}
	if p.pieces[Pawn]&(Rank1|Rank8) != 0 {
		return fmt.Errorf("chess: pawn on the first or last rank")
	}
	want := []struct {
		right    uint8
		king, rk Square
		kp, rp   Piece
	}{
		{CastleWhiteKing, E1, H1, MakePiece(White, King), MakePiece(White, Rook)},
		{CastleWhiteQueen, E1, A1, MakePiece(White, King), MakePiece(White, Rook)},
		{CastleBlackKing, E8, H8, MakePiece(Black, King), MakePiece(Black, Rook)},
		{CastleBlackQueen, E8, A8, MakePiece(Black, King), MakePiece(Black, Rook)},
	}
	for _, w := range want {
		if p.castling&w.right != 0 && (p.board[w.king] != w.kp || p.board[w.rk] != w.rp) {
			return fmt.Errorf("chess: castling right without king and rook on home squares")
		}
	}
	if p.IsAttacked(p.kingSquare(p.side.Opponent()), p.side) {
		return fmt.Errorf("chess: side not to move is in check")
	}
	return nil
}

// FEN returns the position as a FEN record.
func (p *Position) FEN() string {
	var sb strings.Builder
	for r := 7; r >= 0; r-- {
		empty := 0
		for f := 0; f < 8; f++ {
			pc := p.board[MakeSquare(f, r)]
			if pc == NoPiece {
				empty++
				continue
			}
			if empty > 0 {
				sb.WriteByte(byte('0' + empty))
				empty = 0
			}
			sb.WriteString(pc.String())
		}
		if empty > 0 {
			sb.WriteByte(byte('0' + empty))
		}
		if r > 0 {
			sb.WriteByte('/')
		}
	}
	sb.WriteByte(' ')
	sb.WriteString("wb"[p.side : p.side+1])
	sb.WriteByte(' ')
	if p.castling == 0 {
		sb.WriteByte('-')
	} else {
		for i := 0; i < 4; i++ {
			if p.castling&(1<<i) != 0 {
				sb.WriteByte("KQkq"[i])
			}
		}
	}
	sb.WriteByte(' ')
	sb.WriteString(p.ep.String())
	fmt.Fprintf(&sb, " %d %d", p.halfmove, p.fullmove)
	return sb.String()
}
