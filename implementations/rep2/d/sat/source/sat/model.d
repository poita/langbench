/// Checking assignments against formulas.
module sat.model;

import sat.dimacs : Cnf;

/**
 * True if `model` satisfies every clause of `cnf`.
 *
 * `model[i]` is the value of variable `i + 1`; it must cover all variables
 * the clauses mention. An empty clause is never satisfied.
 */
bool satisfies(const Cnf cnf, const(bool)[] model) pure nothrow @nogc @safe
{
    foreach (c; cnf.clauses)
    {
        bool sat = false;
        foreach (l; c)
        {
            const v = (l < 0 ? -l : l) - 1;
            if (v < model.length && model[v] == (l > 0))
            {
                sat = true;
                break;
            }
        }
        if (!sat)
            return false;
    }
    return true;
}

@safe pure nothrow unittest
{
    const cnf = Cnf(2, [[1, -2], [2]]);
    assert(satisfies(cnf, [true, true]));
    assert(!satisfies(cnf, [false, true]));
    assert(!satisfies(Cnf(0, [[]]), []));
    assert(satisfies(Cnf(1, [[1, -1]]), [false]));
}
