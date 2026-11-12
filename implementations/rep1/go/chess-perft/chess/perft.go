package chess

import "sort"

// Perft returns the number of leaf nodes of the legal-move tree of p at the
// given depth: the number of distinct sequences of depth legal moves.
// Perft(p, 0) is 1, and Perft(p, 1) is the number of legal moves. A position
// with no legal moves (checkmate or stalemate) has no nodes at any depth >= 1.
// A negative depth is treated as 0.
//
// The whole tree is walked, with no caching. At depth 1 the moves are counted
// as they are generated, without being played.
func Perft(p *Position, depth int) uint64 {
	if depth <= 0 {
		return 1
	}
	return perft(p, depth)
}

func perft(p *Position, depth int) uint64 {
	var l moveList
	p.generate(&l)
	if depth == 1 {
		return uint64(l.n)
	}
	var n uint64
	for _, m := range l.moves[:l.n] {
		child := p.Make(m)
		n += perft(&child, depth-1)
	}
	return n
}

// DivideEntry is one line of a divide result: a root move and the number of
// leaf nodes below it.
type DivideEntry struct {
	Move  Move
	Nodes uint64
}

// Divide returns, for every legal move of p, the number of leaf nodes of the
// subtree below it at depth-1 plies, sorted by the UCI text of the move. The
// sum of the counts is Perft(p, depth). Divide returns nil if depth < 1.
func Divide(p *Position, depth int) []DivideEntry {
	if depth < 1 {
		return nil
	}
	moves := p.LegalMoves()
	out := make([]DivideEntry, len(moves))
	for i, m := range moves {
		child := p.Make(m)
		out[i] = DivideEntry{m, Perft(&child, depth-1)}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Move.String() < out[j].Move.String() })
	return out
}
