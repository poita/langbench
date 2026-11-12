/**
 * Thistlethwaite's four-phase Rubik's cube solver.
 *
 * The cube group is solved by descending through the chain of subgroups
 *
 * ---
 * G0 = <U,D,L,R,F,B>  >  G1 = <U,D,L,R,F2,B2>  >  G2 = <U,D,L2,R2,F2,B2>
 *    >  G3 = <U2,D2,L2,R2,F2,B2>  >  { identity }
 * ---
 *
 * Phase *i* moves the cube into `G(i)` using only the moves of `G(i-1)`. Each
 * phase has an exact distance table over a small coordinate space, built once
 * when the `Solver` is constructed, so solving a cube is a short greedy
 * descent with no search. Every solution has at most 7 + 10 + 13 + 15 = 45
 * moves.
 *
 * Example:
 * ---
 * auto solver = new Solver;
 * auto scramble = parseMoves("F R U'");
 * auto solution = solver.solve(scramble);
 * assert(CubieCube.fromMoves(scramble ~ solution).isSolved);
 * ---
 */
module rubiks.solver;

import rubiks.coords;
import rubiks.cubie;
import rubiks.move;
import rubiks.phase;

/// Upper bound on solution length (7 + 10 + 13 + 15 moves).
enum size_t maxSolutionLength = 45;

/// Thrown when a cube cannot be solved (it is not a legal cube state).
class UnsolvableException : Exception
{
    import std.exception : basicExceptionCtors;

    mixin basicExceptionCtors;
}

/// A solver holding the four phases' precomputed distance tables.
final class Solver
{
    private Phase[4] _phases;

    /// Builds all distance tables (about a second); reuse the solver for many cubes.
    this()
    {
        auto group = new CornerGroup;
        auto slice12 = Combinations(12, 4);
        auto slice8 = Combinations(8, 4);

        // Moves allowed in each phase.
        Move[] phase1, phase2, phase3, phase4;
        foreach (m; allMoves)
        {
            phase1 ~= m;
            immutable fb = m.face == Face.F || m.face == Face.B;
            if (!fb || m.isHalfTurn)
                phase2 ~= m;
            immutable ud = m.face == Face.U || m.face == Face.D;
            if (ud || (m.isHalfTurn && !ud))
                phase3 ~= m;
            if (m.isHalfTurn)
                phase4 ~= m;
        }

        // Phase 1: orient all edges (reach G1).
        _phases[0] = new Phase("phase 1", phase1.idup,
            [edgeOrientationComponent(phase1)]);

        // Phase 2: orient the corners and put the E-slice edges in the E slice (reach G2).
        _phases[1] = new Phase("phase 2", phase2.idup,
            [cornerOrientationComponent(phase2), eSliceComponent(phase2, slice12)]);

        // Phase 3: corners into the half-turn orbit, M-slice edges into the M slice (reach G3).
        _phases[2] = new Phase("phase 3", phase3.idup,
            [cornerClassComponent(phase3, group), mSliceComponent(phase3, slice8)]);

        // Phase 4: solve everything using half turns only.
        immutable(ubyte)[4] sPos = [0, 2, 4, 6];
        immutable(ubyte)[4] mPos = [1, 3, 5, 7];
        immutable(ubyte)[4] ePos = [8, 9, 10, 11];
        _phases[3] = new Phase("phase 4", phase4.idup, [
            cornerHalfTurnComponent(phase4, group),
            slicePermutationComponent(phase4, sPos),
            slicePermutationComponent(phase4, mPos),
            slicePermutationComponent(phase4, ePos),
        ]);
    }

    /// The four phases, for inspection.
    const(Phase)[] phases() const pure nothrow @safe @nogc
    {
        return _phases[];
    }

    /**
     * Returns a move sequence that solves `cube`. Throws `UnsolvableException`
     * if the cube is not a legal state (for instance a hand-built cube with a
     * twisted corner).
     */
    Move[] solve(const CubieCube cube) const
    {
        if (!cube.isValid)
            throw new UnsolvableException("cube is not a legal cube state");
        CubieCube c = cube;
        Move[] solution;
        solution.reserve(maxSolutionLength);
        foreach (phase; _phases)
            if (!phase.descend(c, solution))
                throw new UnsolvableException("cube is not solvable (" ~ phase.name ~ " failed)");
        return solution;
    }

    /// Solves the cube obtained by applying `scramble` to a solved cube.
    Move[] solve(const(Move)[] scramble) const
    {
        return solve(CubieCube.fromMoves(scramble));
    }
}

version (unittest)
{
    import std.random : Random, uniform;

    // Building the tables takes a moment, so the tests share one solver.
    __gshared Solver sharedSolver;

    Solver testSolver()
    {
        if (sharedSolver is null)
            sharedSolver = new Solver;
        return sharedSolver;
    }
}

unittest
{
    // Table sizes, reachable-state counts and depths match the theory:
    // |G0/G1| = 2^11, |G1/G2| = 3^7 * 495, |G2/G3| = 29400, |G3| = 663552.
    auto s = testSolver;
    auto p = s.phases;
    assert(p[0].size == 2048 && p[0].reachableCount == 2048);
    assert(p[1].size == 2187 * 495 && p[1].reachableCount == 2187 * 495);
    assert(p[2].size == 420 * 70);
    assert(p[3].size == 96 * 24 * 24 * 24 && p[3].reachableCount == 663_552);
    assert(p[0].maxDistance == 7);
    assert(p[1].maxDistance == 10);
    assert(p[2].maxDistance == 13);
    assert(p[3].maxDistance == 15);
    // Every phase has a unique goal at distance zero.
    foreach (ph; p)
    {
        assert(ph.distance[ph.goal] == 0);
        size_t zeros;
        foreach (d; ph.distance)
            zeros += d == 0;
        assert(zeros == 1);
    }
}

unittest
{
    auto s = testSolver;
    assert(s.solve(cast(Move[])[]).length == 0);
    foreach (scramble; ["R", "R'", "R2", "F R U'", "R U R' U' R U R' U' R U R' U' R U R' U' R U R' U' R U R' U'"])
    {
        auto moves = parseMoves(scramble);
        auto sol = s.solve(moves);
        assert(CubieCube.fromMoves(moves ~ sol).isSolved, scramble);
    }
}

unittest
{
    // Superflip, checkerboard, cube-in-cube and a few other famous positions.
    auto s = testSolver;
    foreach (scramble; [
        "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2",
        "U2 D2 R2 L2 F2 B2",
        "F L F U' R U F2 L2 U' L' B D' B' L2 U",
        "U F B' L2 U2 L2 F' B U2 L2 U",
        "R2 L2 D2 B2 F2 U2 R2 L2 D2 B2 F2",
    ])
    {
        auto moves = parseMoves(scramble);
        auto sol = s.solve(moves);
        assert(sol.length <= maxSolutionLength, scramble);
        assert(CubieCube.fromMoves(moves ~ sol).isSolved, scramble);
    }
}

unittest
{
    // Random scrambles of many lengths are solved within the bound.
    auto s = testSolver;
    auto rng = Random(2024);
    size_t worst;
    foreach (i; 0 .. 2000)
    {
        auto moves = new Move[i < 100 ? i % 30 : 25];
        foreach (ref m; moves)
            m = Move(uniform(0, moveCount, rng));
        auto sol = s.solve(moves);
        assert(CubieCube.fromMoves(moves ~ sol).isSolved);
        assert(sol.length <= maxSolutionLength);
        if (sol.length > worst)
            worst = sol.length;
    }
    assert(worst > 20);
}

unittest
{
    // Uniformly random legal states (random walk of 1000 moves).
    auto s = testSolver;
    auto rng = Random(99);
    foreach (_; 0 .. 100)
    {
        auto moves = new Move[1000];
        foreach (ref m; moves)
            m = Move(uniform(0, moveCount, rng));
        auto sol = s.solve(moves);
        assert(CubieCube.fromMoves(moves ~ sol).isSolved);
        assert(sol.length <= maxSolutionLength);
    }
}

unittest
{
    import std.exception : assertThrown;

    // A single twisted corner is not a legal cube.
    auto s = testSolver;
    CubieCube bad;
    bad.co[0] = 1;
    assertThrown!UnsolvableException(s.solve(bad));
}
