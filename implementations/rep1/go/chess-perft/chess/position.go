package chess

// Castling-right bits, as stored in [Position.Castling].
const (
	CastleWhiteKing  uint8 = 1 << iota // K
	CastleWhiteQueen                   // Q
	CastleBlackKing                    // k
	CastleBlackQueen                   // q
)

// Position is a complete chess position: piece placement, side to move,
// castling rights, en passant target and move counters.
//
// A Position is a plain value; copying it copies the whole position. The zero
// value is an empty board and is not a valid chess position. Obtain valid ones
// from [ParseFEN] or [StartPosition].
type Position struct {
	bb       [2][6]Bitboard // bb[color][type]
	occ      [2]Bitboard    // all pieces of each color
	board    [64]Piece
	stm      Color
	castling uint8
	ep       Square // en passant target square, or NoSquare
	halfmove int
	fullmove int
}

// StartFEN is the FEN of the standard starting position.
const StartFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

// StartPosition returns the standard starting position.
func StartPosition() *Position {
	p, err := ParseFEN(StartFEN)
	if err != nil {
		panic(err) // StartFEN is a constant and valid
	}
	return p
}

// SideToMove returns the color whose turn it is.
func (p *Position) SideToMove() Color { return p.stm }

// Castling returns the castling rights as a mask of the Castle* constants.
func (p *Position) Castling() uint8 { return p.castling }

// EnPassant returns the en passant target square, or [NoSquare].
func (p *Position) EnPassant() Square { return p.ep }

// HalfmoveClock returns the halfmove counter. It is carried along but never
// used for any rule.
func (p *Position) HalfmoveClock() int { return p.halfmove }

// FullmoveNumber returns the fullmove counter. It is carried along but never
// used for any rule.
func (p *Position) FullmoveNumber() int { return p.fullmove }

// PieceAt returns the piece on s, or [NoPiece].
func (p *Position) PieceAt(s Square) Piece { return p.board[s] }

// Pieces returns the squares occupied by pieces of color c and type t.
func (p *Position) Pieces(c Color, t PieceType) Bitboard { return p.bb[c][t] }

// Occupied returns the squares occupied by any piece.
func (p *Position) Occupied() Bitboard { return p.occ[White] | p.occ[Black] }

// KingSquare returns the square of c's king.
func (p *Position) KingSquare(c Color) Square { return p.bb[c][King].Lsb() }

// attackersTo returns the pieces of color by that attack s, given occupancy occ.
func (p *Position) attackersTo(s Square, by Color, occ Bitboard) Bitboard {
	b := &p.bb[by]
	return pawnAtt[by.Opposite()][s]&b[Pawn] |
		knightAtt[s]&b[Knight] |
		kingAtt[s]&b[King] |
		BishopAttacks(s, occ)&(b[Bishop]|b[Queen]) |
		RookAttacks(s, occ)&(b[Rook]|b[Queen])
}

// IsAttacked reports whether square s is attacked by any piece of color by.
func (p *Position) IsAttacked(s Square, by Color) bool {
	return p.attackersTo(s, by, p.Occupied()) != 0
}

// InCheck reports whether the side to move is in check.
func (p *Position) InCheck() bool {
	return p.IsAttacked(p.KingSquare(p.stm), p.stm.Opposite())
}

func (p *Position) put(s Square, pc Piece) {
	p.board[s] = pc
	p.bb[pc.Color()][pc.Type()] |= s.Bit()
	p.occ[pc.Color()] |= s.Bit()
}

func (p *Position) remove(s Square) {
	pc := p.board[s]
	p.board[s] = NoPiece
	p.bb[pc.Color()][pc.Type()] &^= s.Bit()
	p.occ[pc.Color()] &^= s.Bit()
}
