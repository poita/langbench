# datalog: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `N` is the input size, `T` the total number of tuples derived (about two
million at most), `p ≤ 60` the number of predicates.

## Algorithm

Bottom-up **semi-naive evaluation**. Parse the input in one pass. Check safety
rule by rule, then compute the strongly connected components of the predicate
dependency graph (Tarjan's or Kosaraju's algorithm); a negative edge inside a
component makes the program unstratifiable. Evaluate the components in
topological order.

Each relation is a set of tuples with hash indexes, one per access pattern
(predicate and set of bound argument positions). Each rule is compiled once
into a join plan: an indexed nested-loop join over its positive atoms, with
negated atoms (membership tests on complete relations) and comparisons applied
as soon as their variables are bound.

A non-recursive component runs each rule once. A recursive component runs
every rule once, then rounds in which, for each positive body atom whose
predicate is in the component, a variant of the rule reads that atom from the
previous round's new tuples (the delta) and the others from the relations as
they stood at the start of the round. Evaluation stops when a round adds
nothing. Queries filter the final relations and sort the matches.

## Required rules

1. **Semi-naive, not naive.** Each derived tuple is a delta in exactly one
   round, and rounds never re-derive from the whole relations. Non-linear rules
   get one variant per recursive atom.
2. **Index maintenance is O(|relation|) per index over the whole run**: no
   index is rebuilt per round.
3. **Join order:** the delta atom first, then repeatedly the atom with the most
   bound arguments (constants or already bound variables), ties in body order.

## Complexity

Parsing, safety and stratification are O(N + p²). The evaluation's cost is that
of the joins, each derived tuple being joined as a delta once. Each query is a
scan of its relation plus sorting its matches.
