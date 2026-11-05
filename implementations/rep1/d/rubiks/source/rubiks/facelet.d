/**
 * The 54-sticker facelet model of the cube, exactly as laid out in the
 * problem statement.
 *
 * Facelet `X n` (face letter, number 1-9 in reading order seen from outside)
 * has index `face * 9 + n - 1` with faces ordered `U R F D L B`.  The
 * facelet model is used to define the moves (from their published 4-cycles),
 * to derive the cubie-level moves of $(MREF rubiks, cubie), and to
 * cross-check everything in the tests; the solver itself never searches on
 * facelets.
 */
module rubiks.facelet;

import rubiks.moves;

/// Number of stickers on the cube.
enum size_t numFacelets = 54;

/// Index of the facelet called `name` (for example `"U9"` or `"B4"`).
uint faceletIndex(string name) pure @safe
{
    if (name.length != 2 || name[1] < '1' || name[1] > '9')
        throw new Exception("bad facelet name '" ~ name ~ "'");
    foreach (f, c; faceLetters)
        if (c == name[0])
            return cast(uint)(f * 9 + (name[1] - '1'));
    throw new Exception("bad facelet name '" ~ name ~ "'");
}

/// Facelet triples of the eight corner positions, U/D facelet first, in the
/// cyclic order used for orientation.
immutable string[3][8] cornerFaceletNames = [
    ["U9", "R1", "F3"], ["U7", "F1", "L3"], ["U1", "L1", "B3"], ["U3", "B1", "R3"],
    ["D3", "F9", "R7"], ["D1", "L9", "F7"], ["D7", "B9", "L7"], ["D9", "R9", "B7"],
];

/// Facelet pairs of the twelve edge positions.  The first facelet is the
/// "primary" one (U/D facelet, or F/B facelet for the middle layer).
immutable string[2][12] edgeFaceletNames = [
    ["U6", "R2"], ["U8", "F2"], ["U4", "L2"], ["U2", "B2"],
    ["D6", "R8"], ["D2", "F8"], ["D4", "L8"], ["D8", "B8"],
    ["F6", "R4"], ["F4", "L6"], ["B6", "L4"], ["B4", "R6"],
];

private immutable string[6] quarterTurnCycles = [
    // U
    "(U1 U3 U9 U7)(U2 U6 U8 U4)(F1 L1 B1 R1)(F2 L2 B2 R2)(F3 L3 B3 R3)",
    // R
    "(R1 R3 R9 R7)(R2 R6 R8 R4)(F3 U3 B7 D3)(F6 U6 B4 D6)(F9 U9 B1 D9)",
    // F
    "(F1 F3 F9 F7)(F2 F6 F8 F4)(U7 R1 D3 L9)(U8 R4 D2 L6)(U9 R7 D1 L3)",
    // D
    "(D1 D3 D9 D7)(D2 D6 D8 D4)(F7 R7 B7 L7)(F8 R8 B8 L8)(F9 R9 B9 L9)",
    // L
    "(L1 L3 L9 L7)(L2 L6 L8 L4)(F1 D1 B9 U1)(F4 D4 B6 U4)(F7 D7 B3 U7)",
    // B
    "(B1 B3 B9 B7)(B2 B6 B8 B4)(U3 L1 D7 R9)(U2 L4 D8 R6)(U1 L7 D9 R3)",
];

private ubyte[numFacelets] identityPerm() pure nothrow @safe @nogc
{
    ubyte[numFacelets] p;
    foreach (i; 0 .. numFacelets)
        p[i] = cast(ubyte) i;
    return p;
}

/// Source table for the quarter turn described by `cycles`: after the move,
/// position `i` holds the sticker that was at `src[i]`.
private ubyte[numFacelets] permFromCycles(string cycles) pure @safe
{
    auto src = identityPerm();
    uint[] cur;
    string word;
    void flushWord()
    {
        if (word.length)
            cur ~= faceletIndex(word);
        word = null;
    }

    foreach (c; cycles)
    {
        if (c == '(')
            cur = null;
        else if (c == ' ')
            flushWord();
        else if (c == ')')
        {
            flushWord();
            foreach (k; 0 .. cur.length)
                src[cur[(k + 1) % cur.length]] = cast(ubyte) cur[k];
        }
        else
            word ~= c;
    }
    return src;
}

/// Source table for "apply `p`, then `q`".
private ubyte[numFacelets] composePerm(in ubyte[numFacelets] p, in ubyte[numFacelets] q) pure nothrow @safe @nogc
{
    ubyte[numFacelets] r;
    foreach (i; 0 .. numFacelets)
        r[i] = p[q[i]];
    return r;
}

private ubyte[numFacelets][numMoves] buildFaceletPerms() pure @safe
{
    ubyte[numFacelets][numMoves] all;
    foreach (f; 0 .. numFaces)
    {
        const one = permFromCycles(quarterTurnCycles[f]);
        const two = composePerm(one, one);
        all[f * 3] = one;
        all[f * 3 + 1] = two;
        all[f * 3 + 2] = composePerm(two, one);
    }
    return all;
}

/// For every move, the facelet source table: after the move, facelet `i`
/// shows the sticker that was on facelet `faceletPerms[move][i]`.
immutable ubyte[numFacelets][numMoves] faceletPerms = buildFaceletPerms();

private ubyte[3][8] buildCornerFacelets() pure @safe
{
    ubyte[3][8] r;
    foreach (i; 0 .. 8)
        foreach (k; 0 .. 3)
            r[i][k] = cast(ubyte) faceletIndex(cornerFaceletNames[i][k]);
    return r;
}

private ubyte[2][12] buildEdgeFacelets() pure @safe
{
    ubyte[2][12] r;
    foreach (i; 0 .. 12)
        foreach (k; 0 .. 2)
            r[i][k] = cast(ubyte) faceletIndex(edgeFaceletNames[i][k]);
    return r;
}

/// Facelet indices of the corner positions (see `cornerFaceletNames`).
immutable ubyte[3][8] cornerFacelets = buildCornerFacelets();
/// Facelet indices of the edge positions (see `edgeFaceletNames`).
immutable ubyte[2][12] edgeFacelets = buildEdgeFacelets();

/**
 * A cube described by the colour of each of its 54 stickers.  A colour is
 * named after the face whose centre has it, so the solved cube has
 * `stickers[i] == i / 9`.
 */
struct FaceletCube
{
    /// Sticker colours, indexed by facelet.
    Face[numFacelets] stickers;

    /// The solved cube.
    static FaceletCube solved() pure nothrow @safe @nogc
    {
        FaceletCube c;
        foreach (i; 0 .. numFacelets)
            c.stickers[i] = cast(Face)(i / 9);
        return c;
    }

    /// Applies one move.
    void apply(Move m) pure nothrow @safe @nogc
    {
        Face[numFacelets] n = void;
        const(ubyte)[] src = faceletPerms[m.id][];
        foreach (i; 0 .. numFacelets)
            n[i] = stickers[src[i]];
        stickers = n;
    }

    /// Applies a sequence of moves, left to right.
    void apply(const(Move)[] moves) pure nothrow @safe @nogc
    {
        foreach (m; moves)
            apply(m);
    }

    /// True if every face shows a single colour.
    bool isSolved() const pure nothrow @safe @nogc
    {
        foreach (i; 0 .. numFacelets)
            if (stickers[i] != i / 9)
                return false;
        return true;
    }

    /// The 54 colours as letters, faces in the order `U R F D L B`.
    string toString() const pure nothrow @safe
    {
        char[numFacelets] s;
        foreach (i; 0 .. numFacelets)
            s[i] = faceLetters[stickers[i]];
        return s.idup;
    }

    /// Parses the format produced by `toString`.
    static FaceletCube fromString(const(char)[] text) pure @safe
    {
        if (text.length != numFacelets)
            throw new Exception("facelet string must have 54 characters");
        FaceletCube c;
        foreach (i, ch; text)
        {
            bool ok;
            foreach (f, l; faceLetters)
                if (l == ch)
                {
                    c.stickers[i] = cast(Face) f;
                    ok = true;
                }
            if (!ok)
                throw new Exception("bad facelet character");
        }
        return c;
    }
}
