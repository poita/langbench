/// Shared helpers for the unit tests.
module support;

import std.random : Mt19937, uniform;

import rubiks;

private __gshared Solver cached;

/// One solver for the whole test run (building the tables takes a moment).
Solver sharedSolver()
{
    if (cached is null)
        cached = new Solver;
    return cached;
}

/// A reproducible random scramble of `length` moves.
Move[] randomScramble(ref Mt19937 rng, size_t length)
{
    auto moves = new Move[length];
    foreach (ref m; moves)
        m = Move.fromId(uniform(0, numMoves, rng));
    return moves;
}

/// Reference check on the facelet model: scramble then solution gives a
/// solved cube.
bool solves(const(Move)[] scramble, const(Move)[] solution)
{
    auto f = FaceletCube.solved();
    f.apply(scramble);
    f.apply(solution);
    return f.isSolved;
}
