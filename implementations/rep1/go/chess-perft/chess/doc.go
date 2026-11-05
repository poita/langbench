// Package chess is a small, fast, fully legal chess move generator with perft
// and divide support.
//
// The package is organised by responsibility:
//
//   - bitboard.go: the Bitboard, Square, Color and Piece types and bit helpers.
//   - tables.go: precomputed leaper tables, rays, between/line sets and the
//     classical ray-lookup slider attack functions.
//   - move.go: the compact Move encoding and UCI formatting.
//   - position.go: the Position type, FEN parsing/printing and attack queries.
//   - makemove.go: in-place Make/Unmake with a small undo record.
//   - movegen.go: the legal move generator (checkers, evasion mask, pins).
//   - perft.go: Perft and Divide.
//
// A Position is parsed from a FEN record and then mutated in place by Make and
// Unmake. The generator only ever produces legal moves, so the number of legal
// moves of a position is simply len(p.LegalMoves()) and perft at depth 1 never
// plays a move.
//
// A Position is not safe for concurrent use; the package-level tables are
// read-only after initialisation.
package chess
