package chess

// MaxMoves is an upper bound on the number of legal moves in any position (the
// true maximum is 218).
const MaxMoves = 256

// moveList is a fixed-capacity move buffer, kept on the stack.
type moveList struct {
	moves [MaxMoves]Move
	n     int
}

func (l *moveList) add(from, to Square) {
	l.moves[l.n] = Move(from) | Move(to)<<6
	l.n++
}

func (l *moveList) addPromotions(from, to Square) {
	for _, t := range [...]PieceType{Queen, Rook, Bishop, Knight} {
		l.moves[l.n] = NewMove(from, to, t, true)
		l.n++
	}
}

// LegalMoves returns all legal moves of the side to move. The order is
// unspecified. A checkmated or stalemated side has no moves.
func (p *Position) LegalMoves() []Move {
	var l moveList
	p.generate(&l)
	return append([]Move(nil), l.moves[:l.n]...)
}

// generate appends exactly the legal moves of p to l.
//
// Legality is established from the checkers of the king and the pieces pinned
// to it: in check, non-king pieces may only capture the checker or interpose;
// a pinned piece may only move along the line through its king. King moves,
// castling and en passant captures are tested directly.
func (p *Position) generate(l *moveList) {
	us, them := p.stm, p.stm.Opposite()
	own, enemy := p.occ[us], p.occ[them]
	occ := own | enemy
	ksq := p.bb[us][King].Lsb()
	checkers := p.attackersTo(ksq, them, occ)

	// King moves: test each destination with the king lifted off the board so
	// that it cannot hide behind itself on a checking slider's line.
	occNoKing := occ &^ ksq.Bit()
	for t := kingAtt[ksq] &^ own; t != 0; {
		to := t.Pop()
		if p.attackersTo(to, them, occNoKing) == 0 {
			l.add(ksq, to)
		}
	}
	if checkers.Count() > 1 {
		return // double check: only the king can move
	}

	// Squares non-king moves may land on: anywhere, or in check, on the checker
	// or the squares between it and the king.
	allowed := ^own
	if checkers != 0 {
		c := checkers.Lsb()
		allowed &= between[ksq][c] | c.Bit()
	}

	// Pieces pinned to the king by an enemy slider.
	var pinned Bitboard
	eb := &p.bb[them]
	snipers := rookRays[ksq]&(eb[Rook]|eb[Queen]) | bishopRays[ksq]&(eb[Bishop]|eb[Queen])
	for snipers != 0 {
		blockers := between[ksq][snipers.Pop()] & occ
		if blockers&(blockers-1) == 0 && blockers&own != 0 { // exactly one, and ours
			pinned |= blockers
		}
	}
	// pinMask is where a piece on s may move: everywhere unless pinned.
	pinMask := func(s Square) Bitboard {
		if pinned.Has(s) {
			return line[ksq][s]
		}
		return ^Bitboard(0)
	}

	ob := &p.bb[us]
	for b := ob[Knight] &^ pinned; b != 0; { // a pinned knight can never move
		from := b.Pop()
		for t := knightAtt[from] & allowed; t != 0; {
			l.add(from, t.Pop())
		}
	}
	for b := ob[Bishop] | ob[Queen]; b != 0; {
		from := b.Pop()
		for t := BishopAttacks(from, occ) & allowed & pinMask(from); t != 0; {
			l.add(from, t.Pop())
		}
	}
	for b := ob[Rook] | ob[Queen]; b != 0; {
		from := b.Pop()
		for t := RookAttacks(from, occ) & allowed & pinMask(from); t != 0; {
			l.add(from, t.Pop())
		}
	}
	p.genPawns(l, allowed, pinMask, occ, ksq)
	if checkers == 0 {
		p.genCastling(l, occ)
	}
}

func (p *Position) genPawns(l *moveList, allowed Bitboard, pinMask func(Square) Bitboard, occ Bitboard, ksq Square) {
	us, them := p.stm, p.stm.Opposite()
	step, startRank, lastRank := 8, 1, 7
	if us == Black {
		step, startRank, lastRank = -8, 6, 0
	}
	enemy := p.occ[them]
	for b := p.bb[us][Pawn]; b != 0; {
		from := b.Pop()
		pm := allowed & pinMask(from)

		one := Square(int(from) + step)
		if occ&one.Bit() == 0 {
			if pm.Has(one) {
				if one.Rank() == lastRank {
					l.addPromotions(from, one)
				} else {
					l.add(from, one)
				}
			}
			if from.Rank() == startRank {
				two := Square(int(from) + 2*step)
				if occ&two.Bit() == 0 && pm.Has(two) {
					l.add(from, two)
				}
			}
		}
		for t := pawnAtt[us][from] & enemy & pm; t != 0; {
			to := t.Pop()
			if to.Rank() == lastRank {
				l.addPromotions(from, to)
			} else {
				l.add(from, to)
			}
		}
		// En passant: the captured pawn is not on the target square, so check
		// and pin masks do not apply; test the resulting position directly.
		if p.ep != NoSquare && pawnAtt[us][from].Has(p.ep) {
			captured := Square(int(p.ep) - step)
			occAfter := occ&^from.Bit()&^captured.Bit() | p.ep.Bit()
			if p.attackersTo(ksq, them, occAfter)&^captured.Bit() == 0 {
				l.add(from, p.ep)
			}
		}
	}
}

func (p *Position) genCastling(l *moveList, occ Bitboard) {
	us, them := p.stm, p.stm.Opposite()
	base, kingside, queenside := Square(0), CastleWhiteKing, CastleWhiteQueen
	if us == Black {
		base, kingside, queenside = 56, CastleBlackKing, CastleBlackQueen
	}
	safe := func(s Square) bool { return p.attackersTo(s, them, occ) == 0 }
	if p.castling&kingside != 0 && occ&(base+5).Bit() == 0 && occ&(base+6).Bit() == 0 &&
		safe(base+5) && safe(base+6) {
		l.add(base+4, base+6)
	}
	if p.castling&queenside != 0 && occ&(base+1).Bit() == 0 && occ&(base+2).Bit() == 0 &&
		occ&(base+3).Bit() == 0 && safe(base+3) && safe(base+2) {
		l.add(base+4, base+2)
	}
}
