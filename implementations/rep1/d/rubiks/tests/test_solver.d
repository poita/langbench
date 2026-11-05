module test_solver;

import std.array : replicate;
import std.exception : assertThrown;
import std.random : Mt19937;

import rubiks;
import rubiks.coord;
import support;

unittest // distance tables have the documented depths
{
    assert(sharedSolver.maxDepths == [7, 10, 13, 15]);
}

unittest // trivial scrambles
{
    auto s = sharedSolver;
    assert(s.solve("").length == 0);
    assert(s.solve("R R'").length == 0);
    assert(s.solve("U U U U").length == 0);
    assert(s.solve("R U R' U' R U R' U' R U R' U' R U R' U' R U R' U' R U R' U'").length == 0);
    assert(solves(parseMoves("R"), s.solve("R")));
    assert(solves(parseMoves("F R U'"), s.solve("F R U'")));
    assert(s.solve("R").length <= 45);
}

unittest // superflip
{
    auto s = sharedSolver;
    enum flip = "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2";
    const sol = s.solve(flip);
    assert(sol.length <= 45);
    assert(solves(parseMoves(flip), sol));
}

unittest // random 25-move scrambles
{
    auto s = sharedSolver;
    auto rng = Mt19937(2024);
    foreach (i; 0 .. 100)
    {
        const scramble = randomScramble(rng, 25);
        const sol = s.solve(formatMoves(scramble));
        assert(sol.length <= 45, "too long");
        assert(solves(scramble, sol));
    }
}

unittest // long scramble and solving a cube state directly
{
    auto s = sharedSolver;
    auto rng = Mt19937(5);
    const scramble = randomScramble(rng, 1000);
    const sol = s.solve(formatMoves(scramble));
    assert(sol.length <= 45);
    assert(solves(scramble, sol));

    CubieCube c;
    c.apply(scramble);
    auto c2 = c;
    c2.apply(s.solve(c));
    assert(c2.isSolved);
}

unittest // each phase ends in its subgroup
{
    auto s = sharedSolver;
    auto rng = Mt19937(31);
    foreach (i; 0 .. 20)
    {
        CubieCube c;
        c.apply(randomScramble(rng, 25));
        // Replay the solution and check the invariants at the phase borders.
        const sol = s.solve(c);
        bool g1, g2;
        foreach (m; sol)
        {
            c.apply(m);
            if (flipCoord(c) == 0 && !g1)
                g1 = true;
            if (g1 && twistCoord(c) == 0 && sliceCoord(c) == subsets12.rank[0xF00])
                g2 = true;
        }
        assert(g1 && g2 && c.isSolved);
    }
}

unittest // illegal cubes are rejected
{
    auto s = sharedSolver;
    CubieCube c;
    c.co[0] = 1;
    assertThrown!UnsolvableException(s.solve(c));
    assertThrown!MoveParseException(s.solve("R U X"));
}
