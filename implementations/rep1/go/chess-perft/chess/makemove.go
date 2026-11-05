package chess

// Undo holds what Unmake needs to restore a position after Make: the captured
// piece, and the castling rights and en passant square before the move.
type Undo struct {
	captured Piece
	castling uint8
	ep       Square
}

// Make plays the legal move m in place and returns the record needed to take it
// back with Unmake. The move must have been generated for the current position.
func (p *Position) Make(m Move) Undo {
	from, to, flag := m.From(), m.To(), m.flag()
	us := p.side
	u := Undo{captured: p.board[to], castling: p.castling, ep: p.ep}
	p.ep = NoSquare

	switch {
	case flag == flagEP:
		capSq := epCaptureSquare(to, us)
		u.captured = p.board[capSq]
		p.remove(capSq)
	case u.captured != NoPiece:
		p.remove(to)
	}

	p.movePiece(from, to)

	switch {
	case flag >= flagPromoN:
		p.remove(to)
		p.put(MakePiece(us, m.Promotion()), to)
	case flag == flagDouble:
		p.ep = (from + to) / 2
	case flag == flagCastle:
		rf, rt := castleRookSquares(from, to)
		p.movePiece(rf, rt)
	}

	p.castling &= castleMask[from] & castleMask[to]
	p.side = us.Opponent()
	return u
}

// Unmake takes back move m, which must be the last move made, using the record
// returned by Make.
func (p *Position) Unmake(m Move, u Undo) {
	from, to, flag := m.From(), m.To(), m.flag()
	us := p.side.Opponent()
	p.side = us

	switch {
	case flag >= flagPromoN:
		p.remove(to)
		p.put(MakePiece(us, Pawn), to)
	case flag == flagCastle:
		rf, rt := castleRookSquares(from, to)
		p.movePiece(rt, rf)
	}

	p.movePiece(to, from)

	switch {
	case flag == flagEP:
		p.put(u.captured, epCaptureSquare(to, us))
	case u.captured != NoPiece:
		p.put(u.captured, to)
	}
	p.castling = u.castling
	p.ep = u.ep
}

// epCaptureSquare returns the square of the pawn captured when side us captures
// en passant onto target.
func epCaptureSquare(target Square, us Color) Square {
	if us == White {
		return target - 8
	}
	return target + 8
}

// castleRookSquares returns the rook's origin and destination for a king move
// from -> to that is a castling.
func castleRookSquares(from, to Square) (Square, Square) {
	if to > from { // kingside
		return to + 1, to - 1
	}
	return to - 2, to + 1
}
