# gitrepo: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `N` objects, `S` an object's payload size, `D` its delta-chain depth,
`E` the entries of a flattened tree, `k` the commits a `log` emits, `F` its
pending set's size.

## Algorithm

One repository state answers every command of the run: the pack indexes, the
packs and the set of loose objects are read once at start-up. An object store
reads objects by id (loose copy first, then the packs in a fixed order),
inflating with a DEFLATE decoder as in the `inflate` problem and applying
deltas to their bases. `log` walks history with a priority queue; `diff`
flattens both trees into (path, mode, id) entries, sorts them by path and
merge-joins them; `cat-file` hashes the object with SHA-1.

## Required rules

1. **Objects are decoded and parsed at most once per run.** Every object
   reconstructed from a pack, including each delta base, is kept for the rest of
   the run, as are parsed commits and trees. Command results (outputs, walks,
   flattened trees) are not memoised.
2. **`log` uses a priority queue** keyed by (committer date descending,
   discovery order ascending), and reads only the commits the walk reaches
   before its limit.
3. **`diff` reads every tree on both sides**; identical subtrees are not
   skipped.
4. **An abbreviated id resolves in O(log N)**, for example by binary search
   over the sorted object ids.
5. **`cat-file` always verifies the SHA-1** of header plus payload.

## Complexity

Index lookup is O(log N). Inflating an object is O(compressed size + S),
applying a delta O(delta + S), and an uncached object costs at most D such
steps. `log` is O(k log F) beyond loading commits, `diff` O(E log E), SHA-1
O(S), and output linear in its size.
