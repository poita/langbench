# orderbook: required implementation approach

SPEC.md defines what the program must output. This note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of stdin into one buffer and parse it in a first pass into a compact
array of commands, collecting every price that appears in a `LIMIT` or
`REPLACE`. Sort and deduplicate those prices and give every price its rank, so
each side of the book is a dense array of price levels indexed by rank. Over
each side's level array keep an array-backed segment tree that stores, per
node, the summed resting quantity and the number of non-empty levels: it finds
the best level, sums crossing liquidity for FOK and walks non-empty levels for
BOOK, each in O(log P) per step (P = number of distinct prices, at most N).
Orders live in one arena of records addressed by integer index; within a level
they form an intrusive doubly linked FIFO list through `prev`/`next` indices, so
fills at the head and cancels from the middle are O(1). One hash map from id
bytes to arena index serves CANCEL and REPLACE. The second pass executes the
commands in order and appends every event to one output buffer, written once
at the end.

## Required choices

1. **Input read once, parsed by hand.** Read the whole input into one buffer
   and walk it with an index: identify the command by its first byte, take ids
   as slices (offset and length) into the buffer, parse numbers with a digit
   loop into 64-bit integers. No per-line or per-token string objects, no
   regular expressions, no general split routines. Parsing is O(input size).
   The last line may lack its trailing newline. In an interpreted language,
   where a per-byte loop costs more than a library call, the equivalent is
   one bulk split of the whole buffer and the built-in integer conversion of
   each numeric token; everything else in this note still applies.
2. **Offline price compression.** The first pass records each command in a
   flat array and collects the `LIMIT`/`REPLACE` prices. Sort and deduplicate
   them (O(N log N)), then convert each command's price to its rank by binary
   search, once. The matching engine works entirely on ranks; the price
   value is looked up in the sorted table only to print it. This makes every
   per-side structure a dense array of size P, with no hashing of prices.
3. **Levels in a dense array per side.** `level[rank]` holds head and tail
   order indices, the 64-bit total remaining quantity and the order count.
   A level is "created" or "removed" just by its count becoming non-zero or
   zero; nothing is allocated or freed.
4. **One segment tree per side over the level array.** An array-backed tree
   (size a power of two at least P) with, per node, the 64-bit sum of level
   totals and the count of non-empty levels. Required operations, all
   O(log P): refresh the path above one leaf after its level changes; descend
   to the lowest (asks) or highest (bids) non-empty rank; prefix or suffix
   sum. A pair of Fenwick trees with binary-lifting descent is an acceptable
   equivalent provided it offers the same operations at the same cost.
5. **FOK check as one range sum.** For a BUY FOK at limit rank r the available
   quantity is the ask-side sum over ranks ≤ r; for a SELL it is the bid-side
   sum over ranks ≥ r. One O(log P) query, independent of how many levels are
   crossed. If it is below `qty`, print `REJECT` and touch nothing.
6. **Matching walks levels best-first through the tree.** While the taker has
   quantity: find the best opposite rank by tree descent, stop if it does not
   cross (compare ranks, not prices; a MARKET has no limit), then consume
   makers from that level's list head, emitting `TRADE`/`FILLED`, decrementing
   the level total and count in place and unlinking filled makers in O(1).
   Refresh the tree path for that level once when leaving it (emptied, or the
   taker done part-way through it), not after every fill. Cost per command is
   O(fills + levels visited × log P).
7. **Order arena with intrusive FIFO links.** An order record holds the id
   slice, side, price rank, 64-bit remaining quantity, `prev`/`next` indices
   and a resting flag. Appending to a level's tail, unlinking from anywhere and
   popping the head are O(1) pointer (index) updates. A record is needed only
   for an order that rests; IOC, FOK, MARKET and fully filled takers never
   get one.
8. **One id map, keyed by the input bytes.** A hash map from id bytes to
   arena index, inserted when an order first rests. The key is a borrowed
   view into the input buffer where the language's map allows it; otherwise
   at most one key copy is made, at insertion. Lookups never allocate. CANCEL and REPLACE do exactly one lookup and
   then check the resting flag (or the map holds only resting orders and
   entries are removed on fill and cancel). Reserve the map's capacity up
   front.
9. **CANCEL and REPLACE are O(1) plus one tree refresh.** CANCEL unlinks the
   order, adjusts its level's total and count and refreshes that leaf's path.
   A priority-kept REPLACE changes the remaining quantity and level total in
   place, keeping its list position. A priority-lost REPLACE unlinks the order,
   matches it as a taker at the new rank, and if quantity remains, appends the
   same arena record to the tail of the new level.
10. **BOOK by ordered tree traversal.** Visit the non-empty leaves in order
    (bids from the highest rank down, asks from the lowest up), skipping any
    subtree whose non-empty count is zero, or repeatedly ask the tree for the
    next non-empty rank. Cost O(k log P) for k printed levels; no collecting,
    sorting or copying of levels.
11. **64-bit quantities throughout.** Level totals, tree sums and order
    remainders are signed or unsigned 64-bit integers.
12. **Output once.** Append every event to one growable byte buffer, with
    integers formatted by a hand-written digit loop (or the standard
    library's append-integer-to-buffer routine) and ids copied straight from
    the input slice, then write the buffer with a single write (or one large
    buffered writer flushed once). An interpreted language collects the
    lines in a list and joins them once.
13. **Hot state reached through locals.** Keep the arena, the level arrays,
    the trees, the id map and the output buffer in a struct or in locals
    passed by reference to the engine functions, not in thread-local globals.

## Left to the implementer

- Segment-tree shape (iterative bottom-up or recursive layout, power-of-two or
  exact size), and whether sum and count share one node record or live in
  parallel arrays; Fenwick trees as allowed in item 4. Whether a leaf change
  recomputes its path or adds a delta along it, and whether the count part
  is touched only when a level turns empty or non-empty.
- Whether the parsed command array stores ranks or prices (ranked on the fly
  during the second pass by binary search).
- Whether the id map stores every resting order ever seen with a resting flag
  or only the currently resting ones.
- Integer widths of indices and ranks (32-bit suffices), struct layout,
  container types, naming and module structure.
- Small caches that keep the structure: remembering the current best rank per
  side, skipping the tree descent while the best level still has orders,
  storing the printed price inside the level record.
- Initial capacities of the arena, map and output buffer, and compiler flags
  beyond a normal optimised release build.

## Pitfalls

- Checking FOK liquidity by popping price levels off a binary heap and pushing
  them back, or by iterating a hash map of levels: the cost grows with the
  number of crossed levels (thousands) times log L, plus allocation, and
  dominates deep-book workloads. Use the O(log P) range sum.
- Producing BOOK by collecting all levels out of a hash map or heap and
  sorting them on every call, or rebuilding a heap afterwards.
- Keeping levels in a hash map keyed by price plus a separate heap of prices
  with lazy deletion and an extra "is in heap" map, which costs several hash
  lookups per insert, cancel and match step.
- Copying id bytes into a freshly allocated string for every command or every
  map lookup (for example converting each byte token to a string to use it as
  a key). Look up with a borrowed view of the input.
- Lazy deletion inside level queues (leaving stale entries for cancelled
  orders to be skipped later) without compaction: queues grow with every
  re-quote and fills must step over dead entries.
- Splitting the input into an array of lines by repeated appending, or each
  line into new token strings, before parsing.
- Refreshing the segment tree after every single fill instead of once per
  level visited.
- Keeping the hot engine state in module-level mutable variables in languages
  where such variables are thread-local by default; every access becomes a
  TLS lookup in the innermost loops.
- Formatting each event with a general-purpose formatted-print call, or
  writing output unbuffered line by line.
- Summing quantities in 32-bit integers (level totals and FOK sums exceed
  2^32).
- Forgetting the degenerate cases: a stream with no `LIMIT` or `REPLACE` has
  an empty price table (P = 0) yet still runs `MARKET`, `CANCEL` and `BOOK`;
  `N` = 0 prints nothing.
