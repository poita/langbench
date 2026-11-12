/// Clause storage used by the solver.
module sat.clause;

import sat.types : Lit;

/// A stored clause of at least two literals. The first two are watched.
final class Clause
{
    /// The literals; `lits[0]` and `lits[1]` are the watched ones.
    Lit[] lits;
    /// True for clauses derived by conflict analysis (eligible for deletion).
    bool learnt;
    /// Set when the clause has been removed; stale watchers are dropped.
    bool deleted;
    /// Clause activity (for learnt clauses).
    double activity = 0.0;

    this(Lit[] lits, bool learnt) pure nothrow @safe
    {
        this.lits = lits;
        this.learnt = learnt;
    }
}
