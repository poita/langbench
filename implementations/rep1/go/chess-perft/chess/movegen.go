package chess

// MaxMoves is an upper bound on the number of legal moves in any position
// (the true maximum is 218). It is the size of the buffer generate needs.
const MaxMoves = 256

// LegalMoves returns the legal moves of the position in a newly allocated slice.
func (p *Position) LegalMoves() []Move {
	var buf [MaxMoves]Move
	n := p.generate(buf[:])
	return append([]Move(nil), buf[:n]...)
}

// CountMoves returns the number of legal moves without allocating.
func (p *Position) CountMoves() int {
	var buf [MaxMoves]Move
	return p.generate(buf[:])
}

// generate writes every legal move of the side to move into out (which must
// have room for MaxMoves) and returns how many it wrote.
//
// Legality is established during generation, so no move needs to be played to
// be tested:
//   - the checkers of the king are found by looking outward from the king;
//   - with two checkers only the king can move; with one, other pieces must
//     land on the evasion mask (the checker and the squares between);
//   - pinned pieces may only move along the line through king and pinner;
//   - king destinations are tested with the king removed from the occupancy;
//   - en passant is tested by an explicit king-safety check after the capture.
func (p *Position) generate(out []Move) int {
	us := p.side
	them := us.Opponent()
	ourOcc, theirOcc := p.colors[us], p.colors[them]
	occ := ourOcc | theirOcc
	ksq := (p.pieces[King] & ourOcc).Lsb()
	kbb := ksq.Bitboard()
	n := 0

	theirPawns := p.pieces[Pawn] & theirOcc
	theirDiag := (p.pieces[Bishop] | p.pieces[Queen]) & theirOcc
	theirOrth := (p.pieces[Rook] | p.pieces[Queen]) & theirOcc

	// Checkers.
	checkers := pawnAttacks[us][ksq]&theirPawns |
		knightAttacks[ksq]&p.pieces[Knight]&theirOcc
	if theirDiag != 0 {
		checkers |= BishopAttacks(ksq, occ) & theirDiag
	}
	if theirOrth != 0 {
		checkers |= RookAttacks(ksq, occ) & theirOrth
	}

	// King moves: sliders x-ray through the king's current square.
	occNoKing := occ ^ kbb
	for dests := kingAttacks[ksq] &^ ourOcc; dests != 0; {
		to := dests.PopLsb()
		if !p.attackedBy(to, them, occNoKing, 0) {
			out[n] = newMove(ksq, to, flagQuiet)
			n++
		}
	}
	if checkers.MoreThanOne() {
		return n
	}

	// Evasion mask.
	target := ^ourOcc
	if checkers != 0 {
		target = betweenBB[ksq][checkers.Lsb()] | checkers
	}

	// Pins.
	var pinned Bitboard
	snipers := rookRays[ksq]&theirOrth | bishopRays[ksq]&theirDiag
	for snipers != 0 {
		s := snipers.PopLsb()
		if b := betweenBB[ksq][s] & occ; b != 0 && !b.MoreThanOne() && b&ourOcc != 0 {
			pinned |= b
		}
	}

	// Knights (a pinned knight can never move).
	for knights := p.pieces[Knight] & ourOcc &^ pinned; knights != 0; {
		from := knights.PopLsb()
		for dests := knightAttacks[from] & target; dests != 0; {
			out[n] = newMove(from, dests.PopLsb(), flagQuiet)
			n++
		}
	}

	// Bishops, rooks and queens.
	for sl := p.pieces[Bishop] & ourOcc; sl != 0; {
		from := sl.PopLsb()
		dests := BishopAttacks(from, occ) & target
		if pinned.Has(from) {
			dests &= lineBB[ksq][from]
		}
		for dests != 0 {
			out[n] = newMove(from, dests.PopLsb(), flagQuiet)
			n++
		}
	}
	for sl := p.pieces[Rook] & ourOcc; sl != 0; {
		from := sl.PopLsb()
		dests := RookAttacks(from, occ) & target
		if pinned.Has(from) {
			dests &= lineBB[ksq][from]
		}
		for dests != 0 {
			out[n] = newMove(from, dests.PopLsb(), flagQuiet)
			n++
		}
	}
	for sl := p.pieces[Queen] & ourOcc; sl != 0; {
		from := sl.PopLsb()
		dests := QueenAttacks(from, occ) & target
		if pinned.Has(from) {
			dests &= lineBB[ksq][from]
		}
		for dests != 0 {
			out[n] = newMove(from, dests.PopLsb(), flagQuiet)
			n++
		}
	}

	// Pawns.
	pawns := p.pieces[Pawn] & ourOcc
	if pawns != 0 {
		var single, double, capL, capR Bitboard
		var sh1, sh2, shL, shR int // origin = destination - shift
		var promoRank Bitboard
		if us == White {
			single = pawns << 8 &^ occ
			double = (single & Rank3) << 8 &^ occ
			capL = (pawns &^ FileA) << 7
			capR = (pawns &^ FileH) << 9
			sh1, sh2, shL, shR = 8, 16, 7, 9
			promoRank = Rank8
		} else {
			single = pawns >> 8 &^ occ
			double = (single & Rank6) >> 8 &^ occ
			capL = (pawns &^ FileA) >> 9
			capR = (pawns &^ FileH) >> 7
			sh1, sh2, shL, shR = -8, -16, -9, -7
			promoRank = Rank1
		}
		n = pawnMoves(out, n, single&target, sh1, flagQuiet, promoRank, ksq, pinned)
		n = pawnMoves(out, n, double&target, sh2, flagDouble, promoRank, ksq, pinned)
		n = pawnMoves(out, n, capL&theirOcc&target, shL, flagQuiet, promoRank, ksq, pinned)
		n = pawnMoves(out, n, capR&theirOcc&target, shR, flagQuiet, promoRank, ksq, pinned)

		// En passant: tested directly on the board after the capture.
		if p.ep != NoSquare {
			capSq := epCaptureSquare(p.ep, us)
			for cands := pawnAttacks[them][p.ep] & pawns; cands != 0; {
				from := cands.PopLsb()
				occAfter := occ&^(from.Bitboard()|capSq.Bitboard()) | p.ep.Bitboard()
				if !p.attackedBy(ksq, them, occAfter, capSq.Bitboard()) {
					out[n] = newMove(from, p.ep, flagEP)
					n++
				}
			}
		}
	}

	// Castling.
	if checkers == 0 {
		if us == White {
			n = p.castleMoves(out, n, occ, them, p.castling&CastleWhiteKing != 0, p.castling&CastleWhiteQueen != 0)
		} else {
			n = p.castleMoves(out, n, occ, them, p.castling&CastleBlackKing != 0, p.castling&CastleBlackQueen != 0)
		}
	}
	return n
}

// pawnMoves appends one move per destination, expanding promotions, and drops
// moves of pinned pawns that leave the pin line. The origin of each move is the
// destination minus shift.
func pawnMoves(out []Move, n int, dests Bitboard, shift int, flag int, promoRank Bitboard, ksq Square, pinned Bitboard) int {
	for dests != 0 {
		to := dests.PopLsb()
		from := Square(int(to) - shift)
		if pinned.Has(from) && !lineBB[ksq][from].Has(to) {
			continue
		}
		if promoRank.Has(to) {
			out[n] = newMove(from, to, flagPromoQ)
			out[n+1] = newMove(from, to, flagPromoR)
			out[n+2] = newMove(from, to, flagPromoB)
			out[n+3] = newMove(from, to, flagPromoN)
			n += 4
			continue
		}
		out[n] = newMove(from, to, flag)
		n++
	}
	return n
}

// castleMoves appends the legal castling moves of the side to move. The king
// must not be in check (the caller checks). The king stands on its home square
// because castling rights are only held while it does.
func (p *Position) castleMoves(out []Move, n int, occ Bitboard, them Color, king, queen bool) int {
	if king || queen {
		home := E1
		if them == White {
			home = E8
		}
		if king {
			f, g := home+1, home+2
			if occ&(f.Bitboard()|g.Bitboard()) == 0 &&
				!p.attackedBy(f, them, occ, 0) && !p.attackedBy(g, them, occ, 0) {
				out[n] = newMove(home, g, flagCastle)
				n++
			}
		}
		if queen {
			d, c, b := home-1, home-2, home-3
			if occ&(d.Bitboard()|c.Bitboard()|b.Bitboard()) == 0 &&
				!p.attackedBy(d, them, occ, 0) && !p.attackedBy(c, them, occ, 0) {
				out[n] = newMove(home, c, flagCastle)
				n++
			}
		}
	}
	return n
}
