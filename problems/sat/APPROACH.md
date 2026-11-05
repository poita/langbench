# sat — required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read stdin with one bulk read, scan the DIMACS integers by hand, and feed the
clauses in input order to a MiniSat-style CDCL solver that reproduces the
search of `reference/main.py` **step for step**: the same literal encoding,
watch-list order, propagation rule, first-UIP analysis with local
minimisation, VSIDS heap, phase saving, Luby restarts and learnt-clause
reduction. Every implementation therefore makes the same decisions, learns
the same clauses and reaches the same number of conflicts on every input;
only the cost per propagation, per conflict and per heap operation differs.
This matters because on these instances a small heuristic change (tie
breaking, restart or deletion policy) moves the conflict count by 2–3x in
either direction, which would swamp any difference in per-operation cost. A
conforming solver prints a model byte-identical to the expected `.out` file on
every satisfiable test and bench input; that is the check that the search
matches.

Sizes: `V` variables, `C` input clauses, `L` total literal occurrences.

## Required choices

1. **Input, O(input size).** One bulk read into a byte buffer; walk it line
   by line, skip blank and `c` lines, take `V` from the `p` line, and parse
   clause integers with a manual digit loop. No per-token strings.
2. **Encoding.** Variable `v` (0-based) is literal `2v` (true) / `2v+1`
   (false); negation is `lit ^ 1`. Truth values are a dense 3-state byte array
   (per literal or per variable). Clauses are identified by an integer
   reference into contiguous storage (a literal arena or per-clause arrays in
   one indexed array), never by a hash map.
3. **Adding input clauses, in input order.** Encode, sort ascending, drop
   duplicates; drop the clause if it has `p` and `¬p`; drop it if any literal
   is already true at the root; remove root-false literals. Empty → UNSAT
   (stop adding). Unit → assign it at level 0 and **propagate immediately**;
   a conflict → UNSAT. Otherwise store it and append its reference to the
   watch lists of its literals at positions 0 and 1.
4. **Watch lists and propagation, two watched literals.** `watches[l]` lists,
   in insertion order, the clauses watching literal `l` (references only, no
   blocker literal). Process the trail with a queue head; for each newly true
   `p`, walk `watches[¬p]` with in-place compaction (read index `i`, write
   index `j`). For each clause: if `c[0] = ¬p` swap `c[0]`, `c[1]`; if `c[0]`
   is true keep the watch; else scan `k = 2, 3, …` for the first literal not
   false, set `c[1] = c[k]`, `c[k] = ¬p`, append the reference to
   `watches[c[1]]` and drop it here; if none, keep it and either report a
   conflict (copy the rest of the list, set the queue head to the trail end,
   return the clause) or assign `c[0]` with this clause as reason. No
   allocation in this loop.
5. **Conflict analysis: first UIP plus local minimisation.** Reuse one `seen`
   array and one learnt buffer. For the conflict clause and then each reason
   on the backward trail walk: bump the clause's activity (learnt clauses
   only); visit its literals **in stored order**, skipping the literal just
   resolved; for each unseen variable above level 0, mark it, bump it, and
   count it if at the current level or append it to the learnt clause (in
   discovery order) otherwise. Stop when the counter reaches zero; the
   negated UIP goes in slot 0. Then drop a literal `q` (slots 1..) when it has
   a reason and every literal of that reason except `¬q` is seen or at level
   0 (one level only, not recursive); `seen` still marks every literal of the
   unminimised clause, dropped ones included, until all of them are cleared
   afterwards. A one-literal result backjumps to level 0; otherwise swap the
   **first** highest-level literal into slot 1; its level is the backjump
   level.
6. **Learning.** Backtrack to that level. A unit learnt clause is assigned at
   level 0 without reason; otherwise store it with activity = current clause
   increment, append it to the watch lists of slots 0 and 1, and assign slot
   0 with it as reason. Then `var_inc /= 0.95`, `cla_inc /= 0.999` (both
   after unit and stored learnts).
7. **VSIDS, O(log V) per operation.** 64-bit float activities. Bump adds
   `var_inc`; above `1e100` scale every activity and `var_inc` by `1e-100`.
   Clause bump adds `cla_inc`; above `1e20` scale all live learnt activities
   and `cla_inc` by `1e-20`. Decisions come from an indexed binary max-heap
   with a position array: variables are inserted in order `0..V-1`; sift-up
   stops when the parent's activity is `>=`; sift-down picks the right child
   only if strictly greater and stops when the child is `<=`; pop moves the
   last element to the root. A bump sifts up a variable that is in the heap.
   `decide` pops until it finds an unassigned variable, opens a new level and
   assigns it its saved phase; an empty heap means every variable is assigned
   and the formula is SAT.
8. **Phase saving and backtracking.** Initial phase is false. Backtracking
   walks the trail from the top down, unassigns each variable, clears its
   reason, saves its phase (the value it had) and re-inserts it in the heap,
   in that order. Truncate the trail and level marks; reset the queue head.
9. **Restarts.** Search runs `i = 0, 1, 2, …` each allow `100·luby(2, i)`
   conflicts (integer Luby sequence as in the reference). The budget is
   checked only after a propagation without conflict, before deciding; a
   restart backtracks to level 0. A conflict at level 0 means UNSAT.
10. **Learnt-clause reduction, only between restarts.** Start with
    `max_learnts = max(⌊stored input clauses / 3⌋, 2000)`. After each restart,
    if the learnt count is `>= max_learnts`: **stable**-sort the learnts by
    activity ascending, delete those in the first `⌊n/2⌋` positions that have
    more than two literals, keep the survivors in sorted order, then clear and
    **rebuild all watch lists**: stored input clauses in storage order, then
    surviving learnts in their new order, each on its current slots 0 and 1.
    Set `max_learnts = ⌊max_learnts · 1.1⌋` (double-precision product,
    truncated). The search is at level 0 here, so no live reason refers to a
    deleted clause and no lock check is needed; reasons of level-0 variables
    are never read again. Cost O(n log n + total live
    literals), a few dozen times per run.
11. **Output.** On SAT, every variable is assigned; write `SAT`, then all `V`
    literals and `0` into one buffer and write it once.

## Left to the implementer

- Clause storage (flat arena with offset/length, or one array per clause),
  whether deleted learnts are compacted or left as garbage, and whether the
  activity lives in the clause record or a parallel array.
- Watch-list containers, integer widths, array-of-structs or
  struct-of-arrays, truth values per literal or per variable.
- Parsing all clauses first or adding them as they are parsed (same order,
  stop adding after UNSAT).
- Module structure, naming, the Luby formula's coding, number formatting,
  bounds-check elimination and other micro-optimisations that do not change
  any decision, learnt clause or watch-list order.

## Pitfalls

- "Improving" the heuristics: blocker literals in watchers, LBD/glue-based
  retention, recursive minimisation, different initial phase, different
  reduction trigger or growth factor, reducing at arbitrary decisions. Each
  changes the search; keeping every low-LBD clause, for example, lets the
  learnt database grow without bound and multiplies the watch visits per
  conflict, and a different deletion schedule can more than double the
  number of conflicts.
- Anything that reorders watch lists or the heap: swap-with-last removal,
  iterating lists backwards, inserting variables into the heap in reverse
  order, an unstable sort in reduction, rebuilding watches in another order.
- Single-precision activities, a differently scaled rescale threshold, or
  floating-point shortcuts that change rounding: multiplying by a
  precomputed `1/0.95` instead of dividing, dividing by `1e100` instead of
  multiplying by `1e-100`, or fast-math compiler modes. Activities tie and
  nearly tie often, so a one-ulp difference changes heap order and the
  whole search.
- Deleting learnt clauses by searching each watch list linearly (and shifting
  its tail) per clause: O(deleted × list length). Rebuild instead.
- Rebuilding watch lists by scanning every clause ever stored (including all
  deleted learnts) instead of the live input and learnt lists.
- Allocating per conflict or per propagation: copying the learnt clause
  twice, building a new watch list per visited literal, growing scratch
  arrays element by element without reuse.
- Allocating a string per token while parsing or per variable while printing,
  or writing the model through many small unbuffered writes.
