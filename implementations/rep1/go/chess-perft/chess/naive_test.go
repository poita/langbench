package chess

import "sort"

// naiveMoves is an independent, deliberately simple reference generator used
// to cross-check the optimised one: it builds pseudo-legal moves from a
// mailbox walk, plays each with Make and discards those leaving the king
// attacked. It shares only Make and IsAttacked with the real generator.
func naiveMoves(p *Position) []Move {
	us := p.stm
	var out []Move
	add := func(from, to Square, promo bool) {
		if promo {
			for _, t := range []PieceType{Queen, Rook, Bishop, Knight} {
				out = append(out, NewMove(from, to, t, true))
			}
			return
		}
		out = append(out, NewMove(from, to, 0, false))
	}
	step := func(s Square, df, dr int) (Square, bool) {
		f, r := s.File()+df, s.Rank()+dr
		if !onBoard(f, r) {
			return 0, false
		}
		return NewSquare(f, r), true
	}
	for s := Square(0); s < 64; s++ {
		pc := p.board[s]
		if pc == NoPiece || pc.Color() != us {
			continue
		}
		switch pc.Type() {
		case Pawn:
			dr, start, last := 1, 1, 7
			if us == Black {
				dr, start, last = -1, 6, 0
			}
			if one, ok := step(s, 0, dr); ok && p.board[one] == NoPiece {
				add(s, one, one.Rank() == last)
				if two, ok := step(one, 0, dr); ok && s.Rank() == start && p.board[two] == NoPiece {
					add(s, two, false)
				}
			}
			for _, df := range []int{-1, 1} {
				if to, ok := step(s, df, dr); ok {
					if p.board[to] != NoPiece && p.board[to].Color() != us || to == p.ep {
						add(s, to, to.Rank() == last)
					}
				}
			}
		case Knight, King:
			deltas := [][2]int{{1, 2}, {2, 1}, {-1, 2}, {-2, 1}, {1, -2}, {2, -1}, {-1, -2}, {-2, -1}}
			if pc.Type() == King {
				deltas = [][2]int{{0, 1}, {1, 0}, {1, 1}, {-1, 1}, {0, -1}, {-1, 0}, {1, -1}, {-1, -1}}
			}
			for _, d := range deltas {
				if to, ok := step(s, d[0], d[1]); ok && (p.board[to] == NoPiece || p.board[to].Color() != us) {
					add(s, to, false)
				}
			}
		default:
			var deltas [][2]int
			if pc.Type() != Bishop {
				deltas = append(deltas, [][2]int{{0, 1}, {1, 0}, {0, -1}, {-1, 0}}...)
			}
			if pc.Type() != Rook {
				deltas = append(deltas, [][2]int{{1, 1}, {-1, 1}, {1, -1}, {-1, -1}}...)
			}
			for _, d := range deltas {
				for to, ok := step(s, d[0], d[1]); ok; to, ok = step(to, d[0], d[1]) {
					if p.board[to] != NoPiece {
						if p.board[to].Color() != us {
							add(s, to, false)
						}
						break
					}
					add(s, to, false)
				}
			}
		}
	}
	// Castling, written out square by square.
	rank := 0
	k, q := CastleWhiteKing, CastleWhiteQueen
	if us == Black {
		rank, k, q = 7, CastleBlackKing, CastleBlackQueen
	}
	sq := func(f int) Square { return NewSquare(f, rank) }
	them := us.Opposite()
	empty := func(fs ...int) bool {
		for _, f := range fs {
			if p.board[sq(f)] != NoPiece {
				return false
			}
		}
		return true
	}
	safe := func(fs ...int) bool {
		for _, f := range fs {
			if p.IsAttacked(sq(f), them) {
				return false
			}
		}
		return true
	}
	if p.castling&k != 0 && empty(5, 6) && safe(4, 5, 6) {
		add(sq(4), sq(6), false)
	}
	if p.castling&q != 0 && empty(1, 2, 3) && safe(4, 3, 2) {
		add(sq(4), sq(2), false)
	}

	legal := out[:0]
	for _, m := range out {
		child := p.Make(m)
		if !child.IsAttacked(child.KingSquare(us), them) {
			legal = append(legal, m)
		}
	}
	return legal
}

func sortedMoves(ms []Move) []Move {
	c := append([]Move(nil), ms...)
	sort.Slice(c, func(i, j int) bool { return c[i] < c[j] })
	return c
}
