# datalog: required implementation approach

SPEC.md defines what the program must output. This note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

## Overall approach

Bottom-up semi-naive evaluation over interned integer constants. Read all of
stdin, lex and parse it in one pass, interning every constant and predicate to a
dense integer id. Check safety, then compute the strongly connected components
of the predicate dependency graph; a negative edge inside a component means
`error`. Renumber constants so that id order is the SPEC total order. Load the
facts, then evaluate the components in topological order: each rule is compiled
once into a join plan (a nested-loop join driven by hash-index lookups, with
negations and comparisons as filters), and a recursive component runs one full
round followed by semi-naive delta rounds until no new tuple appears. Finally
answer the queries by filtering, sorting integer tuples and formatting into one
output buffer.

## Required choices

1. **One-pass lexing and parsing, interning as you go.** Read stdin whole; the
   lexer walks the bytes once and the parser consumes tokens directly. Each
   identifier and integer constant is mapped to a dense id through one hash map
   (identifiers and integers are distinct keys); predicates are mapped by name
   to an id with a fixed arity; variables get per-clause slot numbers, each `_`
   a fresh slot. Parsing is O(input size).
2. **Order-preserving constant ids.** After parsing, sort the distinct constants
   once by the SPEC order (integers numerically, then identifiers bytewise) and
   renumber every constant in rules, facts and queries to its rank. From then on
   constants are plain integers: `=`/`!=`/`<`/... are single integer
   comparisons, output sorting is integer tuple comparison, and printing looks up
   a precomputed text per rank. No string or tagged value appears in the
   evaluation loop.
3. **Static checks.** Safety is a per-rule pass over variable slots. Use
   Tarjan's or Kosaraju's SCC algorithm on the predicate graph (at most 60
   nodes); the program is unstratifiable iff some negative edge has both ends in
   one component. Both checks finish before any evaluation and print only
   `error`.
4. **Evaluate per SCC in topological order.** A component that is a single
   predicate without a self-edge is non-recursive: run each of its rules once
   with the full plan, no fixpoint. A recursive component runs round 0 (every
   rule of the component, full plan), then semi-naive rounds. A body atom is
   *recursive* only if its predicate is in the same component as the head;
   predicates from earlier components are complete and never act as deltas.
5. **Relations are append-only arrays of integer tuples plus a hash set.**
   Store each relation's tuples contiguously in insertion order (a flat id array
   with stride = arity, or fixed-size records), so a tuple has a stable integer
   position. A hash set over the full tuple deduplicates inserts and answers
   membership. The delta of a round is simply the position range
   `[lo, hi)` of tuples appended in the previous round; never copy a delta into
   a separate relation with its own set and indexes.
6. **Semi-naive rounds with a round-start snapshot.** At the start of each
   round record every relation's size `hi`. For each rule and each recursive
   positive body atom, run a delta variant that scans that atom over the
   previous round's range `[lo, hi)` and reads every other positive atom from
   the whole snapshot `[0, hi)`; there is no "old/delta/full" split of the
   other atoms. A variant whose delta range is empty is skipped. A derived head
   tuple already in the relation's set is dropped at once; the others go to a
   buffer that is inserted (deduplicated through the set) and appended right
   after that plan run, so no relation grows while a join scans it. Appended
   tuples are invisible to range scans and index lookups until the next round,
   where they form its delta. Stop when a round appends nothing. Every derived
   tuple is thus a delta exactly once, and non-linear rules get one variant per
   recursive position (SPEC requires this). Round 0 and non-recursive
   components use the same per-run buffer.
7. **Hash indexes per access pattern, built lazily and extended
   incrementally.** An index is identified by (predicate, set of bound argument
   positions) and maps the key values to the positions of matching tuples in
   ascending order. Create it the first time a plan needs it; before running a
   plan, bring each index it uses up to date by indexing only the tuples
   appended since its last update. Indexes are never rebuilt from scratch and
   never modified while a join is running. Total index maintenance is
   O(|relation|) per index over the whole run. Because bucket entries are
   ascending, a scan stops at the first position `>= hi`.
8. **Compiled join plans.** Each rule is compiled once per variant (full plan;
   one delta variant per recursive atom) into a step list with variables as
   integer slots. Order positive atoms with the delta atom first (for delta
   variants), then greedily the atom with the most bound arguments (constants
   or already-bound variables), ties broken by body order. Each step records
   its index (or a full range scan when nothing is bound), which positions bind
   new variables, and repeated-variable equality checks. A positive atom whose
   arguments are all bound is a membership test on the hash set, not an index
   lookup (it may also see tuples inserted in the current round, which is
   sound). Each negated atom and comparison is attached right after the earliest
   step at which all its variables are bound (or before the first step if it has
   none); a negated atom is one hash-set probe on its complete relation. The
   delta atom of a variant is always a range scan, never a probe.
9. **Facts go straight into relations** before evaluation (deduplicated by the
   set); they need no plan.
10. **Queries after evaluation, output buffered once.** For each query scan the
    relation's tuples (or use an existing index if one matches the constant
    positions) checking constants and repeated variables, collect matches,
    sort them by integer tuple, and append `name(v1, v2)` lines using the
    precomputed constant texts plus the `-- N` line to one output buffer that
    is written once at the end.

## Left to the implementer

- Exact hash table types (open addressing, chained buckets via next-pointer
  arrays, or a standard hash map with per-key lists), the hash function as long
  as it is a cheap non-cryptographic mix of the integer ids.
- Tuple layout (flat stride array or fixed 6-slot records), integer width of
  ids (32-bit is enough), and whether membership is a separate set or a
  full-key index.
- Whether join plans run as recursion over steps or as generated loops, and
  whether a delta is iterated in place as a position range or through a plain
  list of its positions.
- Representation of tokens, the AST, error handling for malformed input, module
  layout and naming, compiler flags beyond a normal optimised release build.

## Pitfalls

- Rebuilding hash indexes from scratch every round (or building a fresh
  relation object per delta): with a long chain this is O(rounds x |relation|),
  quadratic in the 2000-step closure.
- Letting a delta range grow during the round, e.g. a later variant scanning
  `[lo, current size)` and so seeing tuples derived by an earlier variant in the
  same round, which then appear again in next round's delta. Each tuple must be
  a delta in exactly one round; otherwise non-linear rules repeat large joins.
- Joining atoms strictly in body order without bound-argument ordering, which
  can turn a selective lookup into a cross product.
- Indexing a fully bound atom (a separate index whose key is the whole tuple,
  allocating a list per tuple) instead of probing the membership set.
- Registering query indexes, or indexes for predicates of later components,
  before evaluation, so every insert during the fixpoint maintains them.
- A node-per-entry hash container for the dedup set, or a keyed
  cryptographic default hasher, on the hot dedup/index path; hashing a string
  or a formatted key instead of the integer ids.
- Comparing or sorting constants through tags, strings or a rank lookup at
  every comparison instead of using order-preserving ids directly.
- Buffering every derivation of a whole round (most of them duplicates of
  known tuples in the dense closures) instead of dropping known tuples at
  derivation time, or re-deriving everything each round (naive evaluation).
- Appending to a relation's tuple array while a join holds a reference into
  it: a reallocation invalidates the scan. Buffer per plan run as in item 6.
- Writing output line by line unbuffered, or formatting integers per tuple
  instead of reusing the precomputed constant texts.
