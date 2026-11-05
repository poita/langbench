package chess

import "sort"

// Perft returns the number of leaf nodes reached by playing every sequence of
// depth legal moves from the position. Perft(0) is 1. A position with no legal
// moves (checkmate or stalemate) contributes no nodes at depth >= 1.
//
// The position is left unchanged. At depth 1 the legal moves are counted
// without being played.
func (p *Position) Perft(depth int) uint64 {
	if depth <= 0 {
		return 1
	}
	buf := make([]Move, MaxMoves*depth)
	return p.perft(depth, buf)
}

func (p *Position) perft(depth int, buf []Move) uint64 {
	n := p.generate(buf[:MaxMoves])
	if depth == 1 {
		return uint64(n)
	}
	var total uint64
	next := buf[MaxMoves:]
	for _, m := range buf[:n] {
		u := p.Make(m)
		total += p.perft(depth-1, next)
		p.Unmake(m, u)
	}
	return total
}

// DivideEntry is one line of a divide result: a root move and the number of
// leaf nodes below it.
type DivideEntry struct {
	Move  Move
	Count uint64
}

// Divide returns, for every legal root move, the number of leaf nodes Perft
// would count below it at depth-1, sorted by the move's UCI string in byte
// order. The sum of the counts equals Perft(depth). depth must be at least 1;
// for smaller values Divide returns nil.
func (p *Position) Divide(depth int) []DivideEntry {
	if depth < 1 {
		return nil
	}
	moves := p.LegalMoves()
	buf := make([]Move, MaxMoves*depth)
	entries := make([]DivideEntry, len(moves))
	for i, m := range moves {
		entries[i].Move = m
		if depth == 1 {
			entries[i].Count = 1
			continue
		}
		u := p.Make(m)
		entries[i].Count = p.perft(depth-1, buf)
		p.Unmake(m, u)
	}
	keys := make([]string, len(entries))
	for i, e := range entries {
		keys[i] = e.Move.String()
	}
	sort.Sort(&byUCI{entries, keys})
	return entries
}

type byUCI struct {
	e []DivideEntry
	k []string
}

func (s *byUCI) Len() int           { return len(s.e) }
func (s *byUCI) Less(i, j int) bool { return s.k[i] < s.k[j] }
func (s *byUCI) Swap(i, j int) {
	s.e[i], s.e[j] = s.e[j], s.e[i]
	s.k[i], s.k[j] = s.k[j], s.k[i]
}
