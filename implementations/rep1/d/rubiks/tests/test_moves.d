module test_moves;

import std.exception : assertThrown;

import rubiks.moves;

unittest // token round trip for all eighteen moves
{
    string[] all;
    foreach (f; "URFDLB")
        foreach (suffix; ["", "2", "'"])
            all ~= f ~ suffix;
    assert(all.length == 18);
    bool[18] seen;
    foreach (tok; all)
    {
        const m = parseMove(tok);
        assert(m.toString == tok);
        assert(!seen[m.id]);
        seen[m.id] = true;
    }
}

unittest // face, turns, inverse
{
    const m = parseMove("R'");
    assert(m.face == Face.R && m.turns == 3);
    assert(m.inverse == parseMove("R"));
    assert(parseMove("F2").inverse == parseMove("F2"));
    assert(Move(Face.B, 1) == parseMove("B"));
}

unittest // invalid tokens
{
    foreach (bad; ["", "r", "R3", "R2'", "R'2", "X", "RR", "2R", "R "])
    {
        Move m;
        assert(!tryParseMove(bad, m), bad);
        assertThrown!MoveParseException(parseMove(bad));
    }
}

unittest // parsing lines
{
    assert(parseMoves("").length == 0);
    assert(parseMoves("   ").length == 0);
    assert(formatMoves(parseMoves("R U R' U' F2 B")) == "R U R' U' F2 B");
    assert(formatMoves(parseMoves("U  D\tL")) == "U D L");
    assertThrown!MoveParseException(parseMoves("R U Q"));
}

unittest // sequence inversion
{
    assert(formatMoves(invertSequence(parseMoves("R U2 F'"))) == "F U2 R'");
    assert(invertSequence([]).length == 0);
}
