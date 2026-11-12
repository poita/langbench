# cardgame: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `N` is the number of objects on the Field (up to a few hundred), `T` the
objects in the match (up to about 16,000, mostly in Vaults), `R` the live
continuous-effect records, `A ≤ R` the live aura records, `F` the cost of one
filter, `C` the script commands (up to about 60,000).

## Algorithm

The card database is parsed once into a tree of effects, selectors, filters,
amounts, conditions and statics, which a tree-walking interpreter evaluates. A
single resumable game engine runs rules processing until it reaches a decision
point, then consumes the next script line. Objects are found by oid in O(1).
Current characteristics come from a whole-board derivation that follows
SPEC.md 14.3 layer by layer over the continuous-effect records in timestamp
order, recomputed only after a state change it could depend on.

## Required rules

1. **Parse the card database once**; nothing is re-parsed while the game runs.
2. **Derive the whole board at once**, in O(N log N + R log R + Σ|affected| +
   A·N·F), evaluating each aura once. No per-object or per-characteristic
   derivation that re-walks all records.
3. **Simulate the match once.** The engine suspends at decision points and
   resumes with the next command. Nothing is replayed from setup, and the game
   state is never copied to try an action.
4. **Check an action directly.** A script action is validated by checking that
   action and its targets (SPEC.md 12), not by building the full `LEGAL` list
   and searching it.
5. **Vault operations are O(1) per card** at either end: draws, mills and digs.

## Complexity

A derivation touches only Field objects, never all `T`; collecting triggers
for an event is O(N). The run is O(C) commands, each costing a bounded number
of derivations and Field scans, plus the work of the effects it resolves.
