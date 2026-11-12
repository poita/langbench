/**
 * Face-turn moves and their textual notation.
 *
 * A move is one of the eighteen outer-layer turns of the cube: a clockwise
 * quarter turn (`U`), a half turn (`U2`) or a counter-clockwise quarter turn
 * (`U'`) of one of the six faces.
 */
module rubiks.move;

import std.exception : basicExceptionCtors;

/// The six faces, in the order used throughout the library.
enum Face : ubyte
{
    U, /// up
    R, /// right
    F, /// front
    D, /// down
    L, /// left
    B, /// back
}

/// Number of distinct moves (6 faces x 3 turn amounts).
enum size_t moveCount = 18;

/// Thrown when a move token or scramble line cannot be parsed.
class MoveParseException : Exception
{
    mixin basicExceptionCtors;
}

/**
 * One of the eighteen face turns.
 *
 * Moves are numbered `face * 3 + (turns - 1)`, so within a face the order is
 * clockwise quarter turn, half turn, counter-clockwise quarter turn.
 */
struct Move
{
    /// Index in `0 .. moveCount`.
    ubyte id;

    /// Builds the move turning `face` clockwise by `turns` quarter turns (1..3).
    this(Face face, int turns) pure nothrow @safe @nogc
    in (turns >= 1 && turns <= 3)
    {
        id = cast(ubyte)(face * 3 + (turns - 1));
    }

    /// Builds a move from its index in `0 .. moveCount`.
    this(size_t id) pure nothrow @safe @nogc
    in (id < moveCount)
    {
        this.id = cast(ubyte) id;
    }

    /// The face that is turned.
    Face face() const pure nothrow @safe @nogc
    {
        return cast(Face)(id / 3);
    }

    /// Number of clockwise quarter turns: 1 (`X`), 2 (`X2`) or 3 (`X'`).
    int turns() const pure nothrow @safe @nogc
    {
        return id % 3 + 1;
    }

    /// True for half turns (`X2`).
    bool isHalfTurn() const pure nothrow @safe @nogc
    {
        return id % 3 == 1;
    }

    /// The move that undoes this one.
    Move inverse() const pure nothrow @safe @nogc
    {
        return Move(face, 4 - turns);
    }

    /// Standard notation: `R`, `R'` or `R2`.
    string toString() const pure nothrow @safe
    {
        static immutable string[moveCount] names = [
            "U", "U2", "U'", "R", "R2", "R'", "F", "F2", "F'",
            "D", "D2", "D'", "L", "L2", "L'", "B", "B2", "B'",
        ];
        return names[id];
    }
}

/// All eighteen moves in index order.
immutable Move[moveCount] allMoves = () {
    Move[moveCount] r;
    foreach (i; 0 .. moveCount)
        r[i] = Move(i);
    return r;
}();

/// Parses a single token such as `U`, `R'` or `F2`.
Move parseMove(const(char)[] token) pure @safe
{
    import std.string : indexOf;

    if (token.length == 0 || token.length > 2)
        throw new MoveParseException("invalid move token '" ~ token.idup ~ "'");
    immutable face = "URFDLB".indexOf(token[0]);
    if (face < 0)
        throw new MoveParseException("invalid move token '" ~ token.idup ~ "'");
    int turns = 1;
    if (token.length == 2)
    {
        if (token[1] == '2')
            turns = 2;
        else if (token[1] == '\'')
            turns = 3;
        else
            throw new MoveParseException("invalid move token '" ~ token.idup ~ "'");
    }
    return Move(cast(Face) face, turns);
}

/**
 * Parses a whitespace-separated sequence of move tokens. An empty (or blank)
 * line yields an empty sequence. Throws `MoveParseException` on a bad token.
 */
Move[] parseMoves(const(char)[] line) pure @safe
{
    Move[] result;
    size_t i = 0;
    while (i < line.length)
    {
        if (line[i] == ' ' || line[i] == '\t' || line[i] == '\r')
        {
            ++i;
            continue;
        }
        size_t j = i;
        while (j < line.length && line[j] != ' ' && line[j] != '\t' && line[j] != '\r')
            ++j;
        result ~= parseMove(line[i .. j]);
        i = j;
    }
    return result;
}

/// Formats a move sequence as space-separated tokens (empty for no moves).
string formatMoves(const(Move)[] moves) pure nothrow @safe
{
    import std.array : appender;

    auto sb = appender!string;
    foreach (i, m; moves)
    {
        if (i)
            sb.put(' ');
        sb.put(m.toString);
    }
    return sb[];
}

/// Returns the sequence that undoes `moves`.
Move[] invertMoves(const(Move)[] moves) pure nothrow @safe
{
    auto r = new Move[moves.length];
    foreach (i, m; moves)
        r[$ - 1 - i] = m.inverse;
    return r;
}

@safe pure unittest
{
    assert(parseMove("U") == Move(Face.U, 1));
    assert(parseMove("R'") == Move(Face.R, 3));
    assert(parseMove("B2") == Move(Face.B, 2));
    assert(parseMove("F").toString == "F");
    assert(Move(Face.L, 3).toString == "L'");
    assert(Move(Face.D, 2).isHalfTurn);
}

@safe pure unittest
{
    import std.exception : assertThrown;

    foreach (bad; ["", "X", "r", "R2'", "R'2", "R3", "RR", "R0", "U ", "2"])
        assertThrown!MoveParseException(parseMove(bad), bad);
    assertThrown!MoveParseException(parseMoves("R U x"));
}

@safe pure unittest
{
    assert(parseMoves("").length == 0);
    assert(parseMoves("R U R' U'").length == 4);
    assert(formatMoves(parseMoves("R U2 F' D L B")) == "R U2 F' D L B");
    assert(formatMoves([]) == "");
    assert(formatMoves(invertMoves(parseMoves("R U2 F'"))) == "F U2 R'");
}

@safe pure unittest
{
    // Every move round-trips through its textual form and has a distinct id.
    foreach (i, m; allMoves)
    {
        assert(m.id == i);
        assert(parseMove(m.toString) == m);
        assert(m.inverse.inverse == m);
        assert(Move(m.face, m.turns) == m);
    }
}
