/**
 * The sticker ("facelet") model of the cube.
 *
 * Every face carries nine stickers numbered 1-9 in reading order. Facelet
 * `f * 9 + (n - 1)` is sticker `n` of face `f` (faces in `Face` order
 * U, R, F, D, L, B). This module holds the raw definition of the cube - the
 * quarter-turn cycles and the facelet triples of the corner and edge cubies -
 * from which `rubiks.cubie` derives its cubie-level moves.
 */
module rubiks.facelets;

import std.array : split;
import rubiks.move;

/// Letters of the faces, indexable by `Face`.
enum string faceLetters = "URFDLB";

/// Number of stickers on the cube.
enum size_t faceletCount = 54;

/// Index of a facelet from its name, e.g. `"U1"` is 0 and `"B9"` is 53.
size_t faceletIndex(string name) pure nothrow @safe @nogc
in (name.length == 2)
{
    size_t face = faceLetters.length;
    foreach (i, c; faceLetters)
        if (c == name[0])
            face = i;
    assert(face < faceLetters.length && name[1] >= '1' && name[1] <= '9');
    return face * 9 + (name[1] - '1');
}

/// Name of a facelet from its index (inverse of `faceletIndex`).
string faceletName(size_t index) pure nothrow @safe
in (index < faceletCount)
{
    return [faceLetters[index / 9], cast(char)('1' + index % 9)].idup;
}

/// The face a facelet lies on.
Face faceOf(size_t facelet) pure nothrow @safe @nogc
{
    return cast(Face)(facelet / 9);
}

// Clockwise quarter turns as 4-cycles of facelets "(a b c d)": the sticker
// at a moves to b, b to c, c to d and d to a.
private immutable string[][6] quarterTurnCycles = [
    // U
    ["U1 U3 U9 U7", "U2 U6 U8 U4", "F1 L1 B1 R1", "F2 L2 B2 R2", "F3 L3 B3 R3"],
    // R
    ["R1 R3 R9 R7", "R2 R6 R8 R4", "F3 U3 B7 D3", "F6 U6 B4 D6", "F9 U9 B1 D9"],
    // F
    ["F1 F3 F9 F7", "F2 F6 F8 F4", "U7 R1 D3 L9", "U8 R4 D2 L6", "U9 R7 D1 L3"],
    // D
    ["D1 D3 D9 D7", "D2 D6 D8 D4", "F7 R7 B7 L7", "F8 R8 B8 L8", "F9 R9 B9 L9"],
    // L
    ["L1 L3 L9 L7", "L2 L6 L8 L4", "F1 D1 B9 U1", "F4 D4 B6 U4", "F7 D7 B3 U7"],
    // B
    ["B1 B3 B9 B7", "B2 B6 B8 B4", "U3 L1 D7 R9", "U2 L4 D8 R6", "U1 L7 D9 R3"],
];

private immutable string[3][8] cornerNames = [
    ["U9", "R1", "F3"], // URF
    ["U7", "F1", "L3"], // UFL
    ["U1", "L1", "B3"], // ULB
    ["U3", "B1", "R3"], // UBR
    ["D3", "F9", "R7"], // DFR
    ["D1", "L9", "F7"], // DLF
    ["D7", "B9", "L7"], // DBL
    ["D9", "R9", "B7"], // DRB
];

private immutable string[2][12] edgeNames = [
    ["U6", "R2"], // UR
    ["U8", "F2"], // UF
    ["U4", "L2"], // UL
    ["U2", "B2"], // UB
    ["D6", "R8"], // DR
    ["D2", "F8"], // DF
    ["D4", "L8"], // DL
    ["D8", "B8"], // DB
    ["F6", "R4"], // FR
    ["F4", "L6"], // FL
    ["B6", "L4"], // BL
    ["B4", "R6"], // BR
];

/// Display names of the corner cubies, in cubie index order.
immutable string[8] cornerCubieNames = [
    "URF", "UFL", "ULB", "UBR", "DFR", "DLF", "DBL", "DRB",
];

/// Display names of the edge cubies, in cubie index order.
immutable string[12] edgeCubieNames = [
    "UR", "UF", "UL", "UB", "DR", "DF", "DL", "DB", "FR", "FL", "BL", "BR",
];

private ubyte[3][8] makeCornerFacelets() pure nothrow @safe @nogc
{
    ubyte[3][8] r;
    foreach (i; 0 .. 8)
        foreach (k; 0 .. 3)
            r[i][k] = cast(ubyte) faceletIndex(cornerNames[i][k]);
    return r;
}

private ubyte[2][12] makeEdgeFacelets() pure nothrow @safe @nogc
{
    ubyte[2][12] r;
    foreach (i; 0 .. 12)
        foreach (k; 0 .. 2)
            r[i][k] = cast(ubyte) faceletIndex(edgeNames[i][k]);
    return r;
}

/**
 * Facelets of each corner position, listed clockwise as seen from outside the
 * cube. The first facelet of every corner lies on the U or D face.
 */
immutable ubyte[3][8] cornerFacelets = makeCornerFacelets();

/// Facelets of each edge position (the two stickers of the cubie).
immutable ubyte[2][12] edgeFacelets = makeEdgeFacelets();

private ubyte[faceletCount][moveCount] makeMoveSources() pure @safe
{
    ubyte[faceletCount][moveCount] r;
    foreach (face; 0 .. 6)
    {
        ubyte[faceletCount] one;
        foreach (i; 0 .. faceletCount)
            one[i] = cast(ubyte) i;
        foreach (cycle; quarterTurnCycles[face])
        {
            auto names = cycle.split(' ');
            assert(names.length == 4);
            foreach (k; 0 .. 4)
                one[faceletIndex(names[(k + 1) % 4])] = cast(ubyte) faceletIndex(names[k]);
        }
        ubyte[faceletCount] two, three;
        foreach (i; 0 .. faceletCount)
        {
            two[i] = one[one[i]];
            three[i] = one[two[i]];
        }
        r[face * 3] = one;
        r[face * 3 + 1] = two;
        r[face * 3 + 2] = three;
    }
    return r;
}

private immutable ubyte[faceletCount][moveCount] moveSources = makeMoveSources();

/**
 * The permutation of stickers performed by `m`: after the move, facelet `i`
 * shows the sticker that was on facelet `source(m)[i]` before it.
 */
ref immutable(ubyte[faceletCount]) faceletSource(Move m) pure nothrow @safe @nogc
{
    return moveSources[m.id];
}

/// Colours (as face indices) of a solved cube, one per facelet.
ubyte[faceletCount] solvedFacelets() pure nothrow @safe @nogc
{
    ubyte[faceletCount] r;
    foreach (i; 0 .. faceletCount)
        r[i] = cast(ubyte)(i / 9);
    return r;
}

/// Applies a move directly to a sticker array.
void applyToFacelets(ref ubyte[faceletCount] state, Move m) pure nothrow @safe @nogc
{
    ubyte[faceletCount] old = state;
    foreach (i; 0 .. faceletCount)
        state[i] = old[moveSources[m.id][i]];
}

/// Renders a sticker array as a 54-character string such as `UUUUUUUUURRR...`.
string faceletString(const ubyte[faceletCount] state) pure nothrow @safe
{
    char[faceletCount] s;
    foreach (i; 0 .. faceletCount)
        s[i] = faceLetters[state[i]];
    return s.idup;
}

@safe pure nothrow unittest
{
    assert(faceletIndex("U1") == 0);
    assert(faceletIndex("U9") == 8);
    assert(faceletIndex("R1") == 9);
    assert(faceletIndex("B9") == 53);
    foreach (i; 0 .. faceletCount)
        assert(faceletIndex(faceletName(i)) == i);
}

@safe pure nothrow unittest
{
    // Example from the specification: after U on a solved cube F1..F3 show
    // the colour of the R centre, L1..L3 show F, B1..B3 show L, R1..R3 show B.
    auto s = solvedFacelets;
    applyToFacelets(s, Move(Face.U, 1));
    foreach (n; 0 .. 3)
    {
        assert(s[faceletIndex("F1") + n] == Face.R);
        assert(s[faceletIndex("L1") + n] == Face.F);
        assert(s[faceletIndex("B1") + n] == Face.L);
        assert(s[faceletIndex("R1") + n] == Face.B);
    }
    // Centres never move.
    foreach (m; allMoves)
    {
        auto t = solvedFacelets;
        applyToFacelets(t, m);
        foreach (f; 0 .. 6)
            assert(t[f * 9 + 4] == f);
    }
}

@safe pure nothrow unittest
{
    // Every move source table is a permutation, and X^4 is the identity.
    foreach (m; allMoves)
    {
        bool[faceletCount] seen;
        foreach (i; 0 .. faceletCount)
        {
            assert(!seen[faceletSource(m)[i]]);
            seen[faceletSource(m)[i]] = true;
        }
        auto s = solvedFacelets;
        foreach (_; 0 .. 4)
            applyToFacelets(s, Move(m.face, 1));
        assert(s == solvedFacelets);
    }
}
