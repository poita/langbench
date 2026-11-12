/**
 * chess-perft: a legal chess move generator with perft and divide.
 *
 * Importing `chessperft` gives the whole public API:
 *
 * $(UL
 *   $(LI `chessperft.types` — colours, pieces, squares, `Move`)
 *   $(LI `chessperft.bitboard` — bitboard helpers and attack tables)
 *   $(LI `chessperft.position` — `Position`, FEN parsing, move application)
 *   $(LI `chessperft.movegen` — legal move generation and counting)
 *   $(LI `chessperft.perft` — `perft` and `divide`)
 *   $(LI `chessperft.query` — the text query format of the CLI)
 * )
 */
module chessperft;

public import chessperft.types;
public import chessperft.bitboard;
public import chessperft.position;
public import chessperft.movegen : MoveList, legalMoves, countLegalMoves;
public import chessperft.perft;
public import chessperft.query;
