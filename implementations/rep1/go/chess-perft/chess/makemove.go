package chess

// castleLoss[s] holds the castling rights that survive a move from or to s.
var castleLoss = func() (m [64]uint8) {
	for i := range m {
		m[i] = 0xF
	}
	m[E1] &^= CastleWhiteKing | CastleWhiteQueen
	m[H1] &^= CastleWhiteKing
	m[A1] &^= CastleWhiteQueen
	m[E8] &^= CastleBlackKing | CastleBlackQueen
	m[H8] &^= CastleBlackKing
	m[A8] &^= CastleBlackQueen
	return
}()

// Make returns the position after playing m, which must be a legal move of p
// (as returned by [Position.LegalMoves]); p itself is not modified.
//
// Make handles captures, en passant, promotion, castling (moving the rook),
// castling-right loss and the en passant target. The halfmove and fullmove
// counters are updated but have no effect on the rules.
func (p *Position) Make(m Move) Position {
	q := *p
	from, to := m.From(), m.To()
	pc := q.board[from]
	us := q.stm
	captured := q.board[to] != NoPiece

	if captured {
		q.remove(to)
	}
	q.remove(from)
	placed := pc
	if promo, ok := m.Promotion(); ok {
		placed = NewPiece(us, promo)
	}
	q.put(to, placed)

	q.ep = NoSquare
	switch pc.Type() {
	case Pawn:
		if from.File() != to.File() && !captured { // en passant
			q.remove(Square(from.Rank()*8 + to.File()))
			captured = true
		}
		if d := int(to) - int(from); d == 16 || d == -16 {
			q.ep = Square((int(from) + int(to)) / 2)
		}
	case King:
		switch int(to) - int(from) {
		case 2: // kingside
			q.remove(to + 1)
			q.put(to-1, NewPiece(us, Rook))
		case -2: // queenside
			q.remove(to - 2)
			q.put(to+1, NewPiece(us, Rook))
		}
	}

	q.castling &= castleLoss[from] & castleLoss[to]
	if pc.Type() == Pawn || captured {
		q.halfmove = 0
	} else {
		q.halfmove++
	}
	if us == Black {
		q.fullmove++
	}
	q.stm = us.Opposite()
	return q
}
