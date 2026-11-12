# sat: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `V` variables, `C` input clauses, `L` literal occurrences.

## Algorithm

A MiniSat-style CDCL solver. Unit propagation uses two watched literals per
clause. Each conflict is analysed to the first UIP, the learnt clause is
minimised, the solver backjumps and asserts it. Branching is VSIDS with phase
saving, the search restarts on the Luby sequence, and low-activity learnt
clauses are deleted periodically. Any satisfying model is accepted.

## Required rules

1. **Input clauses are simplified at the root:** duplicate literals,
   tautologies and root-satisfied clauses are dropped, root-false literals
   removed, and units assigned and propagated at level 0.
2. **Learning:** first-UIP analysis with one level of local (non-recursive)
   minimisation. A unit learnt clause is assigned at level 0.
3. **VSIDS** with double-precision activities: a conflict bumps every variable
   it involves and the learnt clauses it uses; then the variable increment is
   divided by 0.95 and the clause increment by 0.999. Variable activities are
   rescaled by `1e-100` above `1e100`, clause activities by `1e-20` above
   `1e20`. Decisions take the unassigned variable of highest activity.
4. **Phase saving:** a decision assigns the variable's last value, initially
   false.
5. **Luby restarts:** restart `i` allows `100·luby(2, i)` conflicts.
6. **Learnt-clause deletion after a restart**, when there are at least
   `max_learnts` learnt clauses; `max_learnts` starts at
   `max(⌊stored input clauses / 3⌋, 2000)` and is multiplied by 1.1 after each
   reduction. A reduction deletes the lower-activity half of the learnt
   clauses, keeping every binary one.

## Complexity

Parsing and adding clauses are O(L). Choosing a decision variable is O(log V)
amortised (a priority queue on activity). A reduction is O(n log n) in the
learnt count plus the live literals.
