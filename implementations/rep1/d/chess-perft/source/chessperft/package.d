/++
chess-perft: a legal chess move generator with perft and divide.

Import this package to get the whole public API:

$(UL
$(LI `chessperft.position`: `Position`, FEN parsing, make/unmake)
$(LI `chessperft.movegen`: `generateLegal`, `countLegal`, `legalMoves`)
$(LI `chessperft.perft`: `perft`, `divide`)
$(LI `chessperft.query`: the query-line protocol of the CLI)
$(LI `chessperft.move`, `chessperft.types`, `chessperft.bitboard`, `chessperft.tables`:
     supporting types)
)
+/
module chessperft;

public import chessperft.bitboard;
public import chessperft.move;
public import chessperft.movegen;
public import chessperft.perft;
public import chessperft.position;
public import chessperft.query;
public import chessperft.tables;
public import chessperft.types;
