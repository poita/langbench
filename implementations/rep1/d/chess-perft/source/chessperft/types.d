/**
 * Basic value types shared by every other module: colours, piece types,
 * squares, bitboards and moves.
 *
 * Squares are numbered `0 .. 63` with `a1 = 0`, `b1 = 1`, ..., `h1 = 7`,
 * `a2 = 8`, ..., `h8 = 63` (little-endian rank-file mapping), so that
 * `square = rank * 8 + file`.
 */
module chessperft.types;

@safe:

/// A set of squares; bit `n` is set when square `n` is a member.
alias Bitboard = ulong;

/// A square index in `0 .. 63`, or `noSquare`.
alias Square = ubyte;

/// Sentinel meaning "no square" (e.g. no en passant target).
enum Square noSquare = 64;

/// Side to move / piece colour.
enum Color : ubyte
{
    white,
    black,
}

/// The other colour.
Color opposite(Color c) pure nothrow @nogc
{
    return cast(Color)(c ^ 1);
}

/// Kinds of chess piece. `none` marks an empty square.
enum PieceType : ubyte
{
    pawn,
    knight,
    bishop,
    rook,
    queen,
    king,
    none,
}

/// Castling right flags, combined with bitwise or.
enum CastlingRight : ubyte
{
    none = 0,
    whiteKingside = 1,
    whiteQueenside = 2,
    blackKingside = 4,
    blackQueenside = 8,
    all = 15,
}

/// Builds a square index from a zero-based file (`a` = 0) and rank (`1` = 0).
Square makeSquare(int file, int rank) pure nothrow @nogc
{
    return cast(Square)(rank * 8 + file);
}

/// Zero-based file (`a` = 0 .. `h` = 7) of a square.
int fileOf(int sq) pure nothrow @nogc
{
    return sq & 7;
}

/// Zero-based rank (`1` = 0 .. `8` = 7) of a square.
int rankOf(int sq) pure nothrow @nogc
{
    return sq >> 3;
}

/// Returns the algebraic name of a square, e.g. `"e4"`.
string squareName(int sq) @trusted
{
    static immutable string[64] names = () {
        string[64] r;
        foreach (i; 0 .. 64)
            r[i] = [cast(char)('a' + (i & 7)), cast(char)('1' + (i >> 3))].idup;
        return r;
    }();
    return names[sq];
}

/// Parses an algebraic square name such as `"e4"`.
/// Throws: `Exception` when `name` is not a valid square.
Square parseSquare(const(char)[] name) @trusted
{
    if (name.length != 2 || name[0] < 'a' || name[0] > 'h' || name[1] < '1' || name[1] > '8')
        throw new Exception("invalid square: " ~ name.idup);
    return makeSquare(name[0] - 'a', name[1] - '1');
}

/**
 * A move in a position: origin, destination and (for promotions) the piece
 * promoted to. Castling is a king move of two files; en passant is a pawn
 * move onto the en passant square. `Position.play` infers both from the
 * position, so no extra flags are stored.
 */
struct Move
{
    /// Origin square.
    Square from;
    /// Destination square.
    Square to;
    /// Promotion piece (`knight`..`queen`) or `PieceType.none`.
    PieceType promotion = PieceType.none;

    /// UCI long algebraic notation, e.g. `"e2e4"` or `"a7a8q"`.
    string toString() const @trusted
    {
        string s = squareName(from) ~ squareName(to);
        if (promotion != PieceType.none)
            s ~= promotionChar(promotion);
        return s;
    }

    /// Parses a UCI move string (`e2e4`, `a7a8q`).
    /// Throws: `Exception` on malformed input.
    static Move fromUci(const(char)[] s) @trusted
    {
        if (s.length != 4 && s.length != 5)
            throw new Exception("invalid move: " ~ s.idup);
        Move m;
        m.from = parseSquare(s[0 .. 2]);
        m.to = parseSquare(s[2 .. 4]);
        if (s.length == 5)
        {
            switch (s[4])
            {
            case 'n': m.promotion = PieceType.knight; break;
            case 'b': m.promotion = PieceType.bishop; break;
            case 'r': m.promotion = PieceType.rook; break;
            case 'q': m.promotion = PieceType.queen; break;
            default: throw new Exception("invalid promotion piece: " ~ s.idup);
            }
        }
        return m;
    }
}

private string promotionChar(PieceType p) @trusted
{
    switch (p)
    {
    case PieceType.knight: return "n";
    case PieceType.bishop: return "b";
    case PieceType.rook: return "r";
    default: return "q";
    }
}

@safe unittest
{
    assert(makeSquare(4, 3) == 28);
    assert(squareName(28) == "e4");
    assert(parseSquare("h8") == 63);
    assert(parseSquare("a1") == 0);
    assert(fileOf(28) == 4 && rankOf(28) == 3);
    assert(opposite(Color.white) == Color.black);
}

@safe unittest
{
    import std.exception : assertThrown;

    assert(Move.fromUci("e2e4").toString == "e2e4");
    auto m = Move.fromUci("a7a8q");
    assert(m.from == 48 && m.to == 56 && m.promotion == PieceType.queen);
    assert(m.toString == "a7a8q");
    assert(Move.fromUci("b2b1n").toString == "b2b1n");
    assertThrown(Move.fromUci("e2"));
    assertThrown(Move.fromUci("e2e9"));
    assertThrown(Move.fromUci("a7a8k"));
}
