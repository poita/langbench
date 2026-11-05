# cardgame — implementation approach

SPEC.md defines what the program does. This note defines how it does it.
Nothing here changes observable behaviour; where this note and SPEC.md seem to
disagree, SPEC.md wins.

Sizes used below: `N` = objects currently on the Field (up to a few
hundred), `T` = total objects in the match (up to ~16,000, mostly in Vaults),
`R` = live continuous-effect records, `A` = live aura records (`A ≤ R`).

## Overall approach

Read the card database once into a typed, pre-resolved card model and
interpret it with a tree-walking evaluator. Read the match file line by line
and drive a single, resumable game engine: the engine runs rules processing
until it reaches a decision point, then consumes the next script line. Game
state lives in dense arrays indexed by oid, with the Field and the record list
kept permanently in canonical order. Current characteristics come from one
**whole-board derivation pass** whose result is cached and recomputed only
when something it depends on has changed. All output goes to one in-memory
buffer that is written to stdout once at the end (or in large chunks).

## Required choices

1. **Typed card model, built once.** Parse the S-expressions into a typed
   tree: effect, selector, filter, amount, condition, static and target-spec
   nodes carry an enum tag and already-converted operands (integers,
   comparator codes, keyword ids, card-type ids, zone ids, scope ids, event
   ids, interned tag ids, resolved card references). No string comparison,
   symbol lookup or re-parsing happens while the game runs. Evaluation is a
   recursive walk over this tree. Why: the interpreter runs millions of
   filter and selector evaluations; string-matched or raw-list ASTs cost
   several times more per node.

2. **Objects in a dense array indexed by oid.** Each object holds its card
   reference, owner, zone, timestamp and the per-Field state of SPEC 7.5.
   Lookups by oid are O(1); no hash maps keyed by oid on hot paths.

3. **Field kept in canonical order without sorting.** An object entering the
   Field gets a fresh, largest timestamp (control changes keep it), so
   appending on entry and order-preserving removal on exit keeps one Field
   list for both players in `(timestamp, oid)` order at all times. Selectors over the Field scan it in place. Only lists
   that are not naturally ordered (cards gathered from Hand/Ash/Vault/Rift,
   `LEGAL`'s ascending-oid lists, a trigger batch) are sorted, and only the
   matched subset.

4. **Records kept in creation order.** Eids and timestamps are both taken
   from increasing counters at creation, so the list of continuous-effect
   records in creation order is already in `(timestamp, eid)` and eid order.
   Append on creation, remove in place (or mark dead and compact), and never
   re-sort during derivation.

5. **Whole-board derivation in one pass, following SPEC 14.3.** One call
   computes, for every Field object: current controller (layer 1), stripped
   flag, then evaluates each aura record once (activity, arguments, affected
   list — using the layer-1 controllers and base characteristics, so no
   recursion into derivation),
   then applies layers 2, 3, 4, 5, 6 by walking the ordered records once per
   layer. Cost per derivation is O(N + Σ|affected| + A·(cost of one selector
   scan, O(N·filters))). Never derive a single object or a single
   characteristic on demand by re-walking all records, and never derive
   inside a loop over objects.

6. **Derivation results stored per Field object and reused across passes.**
   Write current controller, edge, core, keyword list and stripped flag into
   the object itself or into oid-indexed arrays whose storage persists
   between passes; reset and recompute only the entries of objects on the
   Field. Per-aura scratch (affected lists, evaluated arguments) also reuses
   its storage. A derivation pass allocates nothing proportional to `T`, and
   ideally nothing at all in steady state. Objects off the Field never read
   these entries: their current values are the printed ones and their
   controller is the one recorded when they last left the Field (SPEC 6.2).

7. **Cached derivation with dependency-aware invalidation.** Keep a "derived
   data is stale" flag (or a version counter). Accessors of current
   characteristics re-derive only if stale. Structural changes always mark it
   stale: an object entering or leaving the Field, a record created or
   removed, counters changing, control changing, anything that changes
   whether a source is stripped. Changes that only an aura's selector,
   amount or `when` condition could observe — wounds, ready/exhausted,
   attacking/blocking, Settling/turn number, active player, Spire, Ember,
   the contents or sizes of Hand, Ash, Vault and Rift — mark it stale only
   if a live aura record reads that kind of state. Compute a dependency bit
   mask per aura static when the database is loaded, and keep the union over
   the live aura records (recomputed at the end of each derivation pass,
   which every record creation or removal forces); a mutation tests its bit
   against that union.
   Why: derivation is the dominant cost on aura-heavy boards; re-deriving
   after every wound or Ember change multiplies it.

8. **Trigger collection by a single Field scan per event.** For each event,
   walk the Field once in canonical order and, for each listening object,
   check its trigger abilities by event enum (precomputing each card's
   trigger abilities per event is recommended). Each pending trigger stores
   the key of SPEC 13.3; a batch is sorted once by that key at `settle`.
   `leave` and `dies` abilities of the object that left are collected from
   that object directly (it is no longer on the Field). O(N) per event; no
   per-event copy of the Field or other O(N) allocation.

9. **Targets and legal actions by direct enumeration.** For a target
   specification, build its candidate list once by scanning the relevant
   zone (already ordered by target key, or sorted once). Generate target
   tuples by nested iteration over the per-spec candidate lists, skipping
   tokens already chosen; this yields lexicographic order directly. A script
   action is validated by checking that specific action and its targets
   (SPEC 12), never by building the full `LEGAL` list and searching it.

10. **Resumable engine, no replay.** Rules processing is an explicit state
    machine (or a coroutine/generator) that suspends at decision points and
    resumes with the next command. The match is simulated exactly once;
    nothing is re-run from setup, and the state is never cloned to test an
    action.

11. **Vault as a queue with O(1) ends.** Drawing, milling and digging take
    from the top, and `dig` puts cards on the bottom, each in O(1) per card:
    keep the Vault top-first in an array with a head index (the bottom is
    the array end), or in a ring buffer. Shuffle in place with the SPEC 25
    algorithm applied to the top-first positions.

12. **Buffered output, cheap formatting.** Append each event line and block
    line to a growing byte/string buffer (or a large buffered writer) and
    write it out in large chunks. Format integers and tokens directly into
    the buffer; do not flush per line or build intermediate strings through
    general-purpose formatting machinery on the hot path. Read input fully or
    line-buffered and split on spaces.

## Left to the implementer

- Exact container types, struct layout, and whether derived values live on
  the object or in parallel oid-indexed arrays.
- How the stale flag is represented (boolean, version counter) and how
  finely the dependency bits are split.
- Representation of keyword sets (small list, bitset plus plating total) and
  of tags (interned ids, bitsets).
- Whether trigger abilities are pre-indexed by event per card, and whether
  ordered removal from the Field and record list is eager or via tombstones.
- Module structure, naming, error-handling style, and the specific state
  machine or coroutine mechanism.
- Micro-optimisations that keep the same algorithms (arena allocation,
  buffer reuse, small-vector types, inlining).

## Pitfalls

- Allocating or clearing a derived-characteristics table sized to every
  object in the match on each derivation. Decks hold thousands of cards, so
  this turns an O(N) pass into an O(T) pass and dominates long matches.
- Allocating fresh per-aura result lists, per-aura evaluation contexts,
  copied keyword lists or duplicated selector results on every derivation;
  on aura-heavy boards this is the main cost in garbage-collected or
  allocation-heavy implementations. Reuse buffers.
- Re-sorting the record list or the Field on every derivation or every
  selector evaluation.
- Marking derived data stale on every state change regardless of whether
  any aura can observe it, or deriving once per object or per predicate.
- Comparing type names, tag names, keywords or event names as strings during
  evaluation instead of using pre-resolved ids.
- Removing the top card of the Vault from the front of a contiguous array,
  or inserting `dig`'s leftovers at the front of a reversed one; either
  shifts thousands of elements per card.
- Taking the dependency union over the whole card database instead of the
  live auras, which re-derives after draws, turn changes and wounds on
  boards where nothing reads them.
- Copying the whole Field (or another zone) for every event, every selector
  evaluation or every trigger collection when the scan does not mutate it.
- Building all target tuples and then sorting them, or recomputing a
  candidate list inside the tuple loop, instead of enumerating ordered
  candidate lists once.
- Validating an action by generating the complete legal-action list.
- Writing output unbuffered or flushing per line; producing each event line
  through several temporary string concatenations.
