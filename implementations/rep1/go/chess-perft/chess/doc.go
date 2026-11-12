// Package chess is a small, dependency-free legal move generator for standard
// chess, built to answer perft and divide queries quickly.
//
// A [Position] is a value type holding a bitboard representation of a chess
// position. Positions are created with [ParseFEN] or [StartPosition], their
// legal moves are listed with [Position.LegalMoves], and a move is played with
// [Position.Make], which returns the resulting position and leaves the receiver
// untouched (copy-make), so no unmake step is needed.
//
// [Perft] counts the leaf nodes of the legal-move tree to a given depth and
// [Divide] reports that count per root move:
//
//	pos, _ := chess.ParseFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
//	n := chess.Perft(pos, 3) // 8902
//
// # Design
//
// The move generator is a legal generator: it computes the checkers of the
// side to move and the pieces pinned to its king, and uses those to restrict
// the moves it emits, so that (apart from king moves, en passant captures and
// castling, which are tested explicitly) no generated move needs to be played
// to find out whether it is legal. Perft therefore counts leaves at depth one
// by generating moves without playing them (bulk counting). There is no
// transposition table or any other caching; the whole tree is walked.
//
// The package is organised by responsibility:
//
//   - bitboard.go: [Bitboard], [Square] and the basic bit operations;
//   - tables.go: precomputed attack, ray, "between" and "line" tables and the
//     sliding-piece attack functions;
//   - piece.go: [Color], [PieceType] and [Piece];
//   - move.go: [Move] and its UCI text form;
//   - position.go: [Position] and its accessors;
//   - fen.go: FEN parsing and formatting;
//   - movegen.go: legal move generation;
//   - makemove.go: playing a move;
//   - perft.go: [Perft] and [Divide].
package chess
