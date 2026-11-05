/**
 * The solver: Thistlethwaite's four-phase algorithm with an exact distance
 * table per phase and greedy descent.
 */
module rubiks.solver;

import std.exception : enforce;

import rubiks.cubie;
import rubiks.movetables;
import rubiks.moves;
import rubiks.phases;

/// Thrown when a cube cannot be solved (for example an illegal state).
class UnsolvableException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Solves cubes.  Constructing a `Solver` builds the four distance tables
 * (about a second); after that, `solve` takes microseconds and the object can
 * be shared by any number of calls (all methods are `const`).
 *
 * Phase lengths are optimal for their move sets, so a solution has at most
 * 7 + 10 + 13 + 15 = 45 moves.
 */
final class Solver
{
    /// Upper bounds on the lengths of phases 1 to 4.
    static immutable uint[4] phaseBounds = [7, 10, 13, 15];

    private const(MoveTables) tables;
    private Phase1 p1;
    private Phase2 p2;
    private Phase3 p3;
    private Phase4 p4;
    private ubyte[] d1, d2, d3, d4;

    /// Builds the move tables and the four distance tables.
    this()
    {
        auto mt = new MoveTables;
        tables = mt;
        p1 = Phase1(mt);
        p2 = Phase2(mt);
        p3 = Phase3(mt);
        p4 = Phase4(mt);
        d1 = buildDistances(p1);
        d2 = buildDistances(p2);
        d3 = buildDistances(p3);
        d4 = buildDistances(p4);
    }

    /// The greatest finite distance in each phase's table (7, 10, 13, 15).
    uint[4] maxDepths() const
    {
        uint[4] r;
        foreach (i, d; [d1, d2, d3, d4])
            foreach (v; d)
                if (v != unreached && v > r[i])
                    r[i] = v;
        return r;
    }

    /**
     * Returns a move sequence that solves `cube` (applying it to `cube`
     * yields the solved cube).  Throws $(LREF UnsolvableException) if `cube`
     * is not a legal state.
     */
    Move[] solve(in CubieCube cube) const
    {
        enforce(cube.isSolvable, new UnsolvableException("cube state is not solvable"));
        CubieCube c = cube;
        Move[] solution;
        solution.reserve(48);
        descend(p1, d1, c, solution);
        descend(p2, d2, c, solution);
        descend(p3, d3, c, solution);
        descend(p4, d4, c, solution);
        assert(c.isSolved);
        return mergeSameFace(solution);
    }

    /// Solves the cube obtained by applying the space-separated `scramble`
    /// to a solved cube.
    Move[] solve(const(char)[] scramble) const
    {
        CubieCube c;
        foreach (m; MoveRange(scramble))
            c.apply(m);
        return solve(c);
    }

    /// Merges adjacent moves of the same face (`F F2` becomes `F'`) and drops
    /// pairs that cancel; phase boundaries are where these occur.
    private static Move[] mergeSameFace(const(Move)[] moves)
    {
        Move[] r;
        r.reserve(moves.length);
        foreach (m; moves)
        {
            if (r.length && r[$ - 1].face == m.face)
            {
                const t = (r[$ - 1].turns + m.turns) % 4;
                r = r[0 .. $ - 1];
                if (t != 0)
                    r ~= Move(m.face, t);
            }
            else
                r ~= m;
        }
        return r;
    }

    /// Greedy descent: repeatedly take the first move that lowers the exact
    /// distance by one.
    private static void descend(P)(const P phase, const(ubyte)[] dist, ref CubieCube cube, ref Move[] solution)
    {
        uint c = phase.encode(cube);
        enforce(dist[c] != unreached, new UnsolvableException("state not reachable in phase"));
        while (dist[c] != 0)
        {
            const want = cast(ubyte)(dist[c] - 1);
            bool moved;
            foreach (m; P.moves)
            {
                const n = phase.step(c, m);
                if (dist[n] == want)
                {
                    const mv = Move.fromId(m);
                    cube.apply(mv);
                    solution ~= mv;
                    c = n;
                    moved = true;
                    break;
                }
            }
            assert(moved);
        }
    }
}
