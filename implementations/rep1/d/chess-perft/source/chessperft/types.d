/++
Basic chess vocabulary: colours, piece types, the packed piece code stored in
the board mailbox, castling-right bits and square names.
+/
module chessperft.types;

/// Side of a player.
enum Color : int
{
    white = 0,
    black = 1,
}

/// The other side.
pragma(inline, true)
Color opposite(Color c) @safe pure nothrow @nogc
{
    return cast(Color)(c ^ 1);
}

/// Kind of piece, ignoring colour. The values index per-type bitboards.
enum PieceType : int
{
    pawn = 0,
    knight = 1,
    bishop = 2,
    rook = 3,
    queen = 4,
    king = 5,
}

/++
A coloured piece packed in one byte: the piece type in the low three bits and
the colour in bit 3. `noPiece` marks an empty square.
+/
alias Piece = ubyte;

/// Mailbox value of an empty square.
enum Piece noPiece = 0xFF;

/// Pack a colour and a piece type into a `Piece`.
pragma(inline, true)
Piece makePiece(Color c, PieceType t) @safe pure nothrow @nogc
{
    return cast(Piece)(t | (c << 3));
}

/// Piece type of a (non-empty) piece.
pragma(inline, true)
PieceType typeOf(Piece p) @safe pure nothrow @nogc
{
    return cast(PieceType)(p & 7);
}

/// Colour of a (non-empty) piece.
pragma(inline, true)
Color colorOf(Piece p) @safe pure nothrow @nogc
{
    return cast(Color)(p >> 3);
}

/// Bits of the castling-rights mask.
enum ubyte whiteKingside = 1;
enum ubyte whiteQueenside = 2; /// ditto
enum ubyte blackKingside = 4; /// ditto
enum ubyte blackQueenside = 8; /// ditto
enum ubyte allCastling = 15; /// ditto

/// Square indices that the rules refer to by name.
enum : int
{
    a1 = 0, b1 = 1, c1 = 2, d1 = 3, e1 = 4, f1 = 5, g1 = 6, h1 = 7,
    a8 = 56, b8 = 57, c8 = 58, d8 = 59, e8 = 60, f8 = 61, g8 = 62, h8 = 63,
}

/++
Algebraic name (`"e4"`) of a square index.
Params:
    sq = square index in `0 .. 64`
+/
string squareName(int sq) @safe pure nothrow
{
    char[2] s = [cast(char)('a' + (sq & 7)), cast(char)('1' + (sq >> 3))];
    return s.idup;
}

/++
Square index of an algebraic name such as `"e4"`.
Returns: the index, or -1 if `name` is not a valid square.
+/
int squareFromName(const(char)[] name) @safe pure nothrow @nogc
{
    if (name.length != 2 || name[0] < 'a' || name[0] > 'h' || name[1] < '1' || name[1] > '8')
        return -1;
    return (name[1] - '1') * 8 + (name[0] - 'a');
}
