/**
 * Move notation: faces, the eighteen move tokens, and parsing / formatting.
 *
 * A $(LREF Move) is a face plus a number of clockwise quarter turns (1, 2 or
 * 3).  Its textual form is the usual one: `R` (quarter turn), `R2` (half
 * turn), `R'` (counter-clockwise quarter turn).
 */
module rubiks.moves;

import std.array : appender, array;

/// The six faces, in the order used for indexing throughout the library.
enum Face : ubyte
{
    U, /// up
    R, /// right
    F, /// front
    D, /// down
    L, /// left
    B, /// back
}

/// Number of faces.
enum uint numFaces = 6;
/// Number of distinct moves (6 faces x 3 turn amounts).
enum uint numMoves = 18;

/// Letters of the faces, indexed by `Face`.
immutable string faceLetters = "URFDLB";

/// Thrown when text cannot be parsed as a move sequence.
class MoveParseException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * One of the eighteen face moves.
 *
 * The move is stored as a single index `face * 3 + (turns - 1)`, so that
 * all moves of a face are adjacent and the index is usable in tables.
 */
struct Move
{
    /// Index in `0 .. numMoves`.
    ubyte id;

    /// Builds the move turning `face` clockwise `turns` times (1, 2 or 3).
    this(Face face, int turns) pure nothrow @safe @nogc
    in (turns >= 1 && turns <= 3)
    {
        id = cast(ubyte)(face * 3 + (turns - 1));
    }

    /// Builds a move from its table index.
    static Move fromId(uint id) pure nothrow @safe @nogc
    in (id < numMoves)
    {
        Move m;
        m.id = cast(ubyte) id;
        return m;
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

    /// The move that undoes this one.
    Move inverse() const pure nothrow @safe @nogc
    {
        return Move(face, 4 - turns);
    }

    /// Token text: `"R"`, `"R2"` or `"R'"`.
    string toString() const pure nothrow @safe @nogc
    {
        return moveNames[id];
    }
}

private immutable string[numMoves] moveNames = [
    "U", "U2", "U'", "R", "R2", "R'", "F", "F2", "F'",
    "D", "D2", "D'", "L", "L2", "L'", "B", "B2", "B'",
];

/// Parses a single token such as `U`, `R2` or `F'`; returns false if invalid.
bool tryParseMove(const(char)[] token, out Move move) pure nothrow @safe @nogc
{
    if (token.length < 1 || token.length > 2)
        return false;
    int face;
    switch (token[0])
    {
    case 'U': face = Face.U; break;
    case 'R': face = Face.R; break;
    case 'F': face = Face.F; break;
    case 'D': face = Face.D; break;
    case 'L': face = Face.L; break;
    case 'B': face = Face.B; break;
    default: return false;
    }
    int turns = 1;
    if (token.length == 2)
    {
        if (token[1] == '2')
            turns = 2;
        else if (token[1] == '\'')
            turns = 3;
        else
            return false;
    }
    move = Move(cast(Face) face, turns);
    return true;
}

/// Parses a single token; throws $(LREF MoveParseException) if invalid.
Move parseMove(const(char)[] token) pure @safe
{
    Move m;
    if (!tryParseMove(token, m))
        throw new MoveParseException("invalid move token '" ~ token.idup ~ "'");
    return m;
}

/**
 * Lazily splits a line into moves.  Tokens are separated by one or more
 * whitespace characters; an empty or blank string yields no moves.  Throws
 * $(LREF MoveParseException) while iterating if a token is invalid.
 */
struct MoveRange
{
    private const(char)[] rest;
    private Move cur;
    private bool done;

    /// Starts iterating over the moves in `text`.
    this(const(char)[] text) pure @safe
    {
        rest = text;
        advance();
    }

    /// True when all moves have been consumed.
    bool empty() const pure nothrow @safe @nogc
    {
        return done;
    }

    /// The current move.
    Move front() const pure nothrow @safe @nogc
    {
        return cur;
    }

    /// Moves on to the next token.
    void popFront() pure @safe
    {
        advance();
    }

    private static bool isSpace(char c) pure nothrow @safe @nogc
    {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n';
    }

    private void advance() pure @safe
    {
        size_t i = 0;
        while (i < rest.length && isSpace(rest[i]))
            ++i;
        if (i == rest.length)
        {
            done = true;
            rest = rest[i .. $];
            return;
        }
        size_t j = i;
        while (j < rest.length && !isSpace(rest[j]))
            ++j;
        cur = parseMove(rest[i .. j]);
        rest = rest[j .. $];
    }
}

/// Parses a whole line of space-separated tokens into an array of moves.
Move[] parseMoves(const(char)[] text) pure @safe
{
    return MoveRange(text).array;
}

/// Inverse of a sequence: the moves reversed, each inverted.
Move[] invertSequence(const(Move)[] moves) pure nothrow @safe
{
    auto result = new Move[moves.length];
    foreach (i, m; moves)
        result[moves.length - 1 - i] = m.inverse;
    return result;
}

/// Appends the tokens of `moves`, separated by single spaces, to `sink`
/// (any output range of `char`).  No trailing newline is written.
void writeMoves(Sink)(ref Sink sink, const(Move)[] moves)
{
    import std.range.primitives : put;

    foreach (i, m; moves)
    {
        if (i != 0)
            put(sink, ' ');
        put(sink, m.toString);
    }
}

/// Formats a move sequence as a single space-separated string.
string formatMoves(const(Move)[] moves) pure @safe
{
    auto app = appender!string;
    writeMoves(app, moves);
    return app.data;
}
