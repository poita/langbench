# diff — required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of standard input into memory with one bulk read and walk it line by
line, taking lines as views into that buffer and reading content strictly by
the declared counts. For `diff`, intern every line of A and B into a dense
integer id with one hash map, trim the common prefix and suffix, and run
Myers' algorithm in its **linear-space divide-and-conquer form** (the
"middle snake" variant, Myers 1986 section 4b) on the id arrays. The recursion
appends `(tag, line index)` operations in script order to one array; the
output is then produced from that array into one buffer and written once.
For `patch`, make one linear pass over the script and build the output the
same way.

Sizes below: `N` and `M` are the line counts of A and B, `D` is the minimum
edit cost, `L` is the total input size in bytes.

## Required choices

1. **Input, O(L).** One bulk read of stdin into a single byte buffer. Lines
   are (start, end) views into it, found by scanning for `\n`; a `\r` before
   `\n` is dropped for the CRLF leniency. Do not copy each line into its own
   string unless the language has no cheap slice type. Count lines are parsed
   with a manual digit loop after stripping trailing spaces and tabs. Content
   is consumed by count only, never by inspecting its text.
2. **Line interning, O(L) expected.** One hash map from line bytes to a dense
   `int32` id, shared by A and B and filled in input order. A key is looked up
   by its bytes; a new key is stored once (as a view or one copy). After
   interning, A and B are two integer arrays and every equality test in the
   algorithm is one integer comparison. Line text is never compared inside the
   search.
3. **Prefix/suffix trimming.** Strip the longest common prefix and suffix of
   the id arrays before the search; they are emitted as keeps. Repeat the same
   trim at the start of every recursive call (it costs only the length
   trimmed).
4. **Core algorithm: linear-space Myers, O((N+M)·D) time, O(N+M) space.** A
   recursive procedure on a sub-rectangle `A[a0:a1] × B[b0:b1]`, given as index
   bounds into the full arrays (or as non-copying views of them):
   - trim the common prefix and suffix (item 3);
   - if one side is now empty, emit all deletes or all inserts and return;
   - otherwise find the middle snake, recurse on the rectangle before it,
     emit the snake's diagonal moves as keeps, and recurse on the rectangle
     after it.
   After trimming, both sides non-empty implies `D ≥ 2`, and the middle snake
   splits the problem into two parts each with strictly smaller cost, so the
   recursion terminates with depth O(log D) and total work O((N+M)·D).
5. **Middle snake.** For a rectangle with `n` and `m` lines and
   `Δ = n − m`, run the greedy furthest-reaching search forward from `(0,0)`
   and backward from `(n,m)` in lockstep for `d = 0, 1, …, ⌈(n+m)/2⌉`,
   stepping diagonals `k = −d, −d+2, …, d` and following each snake with
   integer comparisons. When `Δ` is odd, test for overlap after each forward
   extension against the backward frontier of round `d−1`; when `Δ` is even,
   test after each backward extension against the forward frontier of round
   `d`. The overlapping snake is the middle snake. The two frontier arrays
   (`V_f`, `V_b`, indexed by diagonal plus an offset) are allocated once,
   sized `O(N+M)` for the top-level problem, and reused by every call; only
   the entries a round reads are initialised.
6. **No saved frontiers, no table.** Do not keep a copy of `V` per round for a
   later backtrack, and do not build an `N×M` LCS table. Memory is O(N+M)
   apart from the input and output buffers.
7. **Script representation.** One operations array, reserved for `N+M`
   entries, holding a tag and either a line index (into A for keep/delete,
   into B for insert) or nothing more, the indices then being recovered at
   output time by walking A and B in step. The recursion appends in final
   script order, so no reversal, prepending or concatenation of partial
   scripts is needed. Line text is not copied into the script.
8. **Exactness.** The result must be minimal for every input: no
   cost-bounded cutoffs, no "too expensive" heuristics, no discarding of
   lines unique to one file, no anchoring on unique lines (patience,
   histogram). Every implementation performs the same exact search.
9. **Output, O(output size).** After the diff, write the count line (the
   length of the operations array), then for each operation the tag, the line
   bytes from the input buffer and `\n`, all appended into one output buffer
   (or one large buffered writer) that is written once at the end.
10. **Patch, O(L).** Read A by count, then walk the `K` script lines once with
    an index into A: keep appends A's next line, delete advances the index,
    insert appends the script line after its tag. Collect output references
    (or append into the body buffer while counting), then write the count
    line and the body in one write. No interning and no diff work.

## Left to the implementer

- Container types, struct layout, naming, module structure, and whether the
  recursion is written recursively or with an explicit stack.
- The hash map type and hash function, as long as lookups are expected O(1)
  and keyed by line bytes.
- Whether the base case also handles `D = 1` directly, and whether tiny
  rectangles use a direct scan, provided the result is minimal and the
  complexity above holds.
- How the middle-snake coordinates are encoded (backward search in reversed
  coordinates or in absolute ones), and which of several equally short
  scripts results (SPEC accepts any minimal one).
- Loop-level micro-optimisations: bounds-check elimination, `int32` versus
  native-int indices, pointer or index style, unrolling of the snake loop.
- Whether input lines are pre-split into an array of views or scanned
  lazily as the counts are read.

## Pitfalls

- The forward-only greedy search that saves a snapshot of `V` every round
  for backtracking: O(D²) memory, hundreds of megabytes at `D ≈ 7000`, and its
  allocation and page-fault cost dominates. Saving the full `2d+1` window per
  round, or growing one big buffer for it by repeated reallocation, doubles or
  triples that.
- An O(N·M) LCS table (25 million cells at the limits), or a bit-parallel
  LCS, in place of Myers.
- Comparing line strings or hashing lines inside the snake loop instead of
  comparing interned integer ids.
- Running the overlap test without checking that the opposite frontier's
  diagonal lies inside the range that frontier has reached (`|k−Δ| ≤ d−1` or
  `≤ d`). Because `V_f`/`V_b` are reused and not cleared, an out-of-range
  entry holds a stale value from an earlier call and yields a wrong snake.
- Copying sub-arrays for each recursive call (array slicing that copies, in
  languages where it does) instead of passing index bounds; allocating fresh
  `V` arrays per call; clearing the whole `V` array per call.
- Building the script by prepending, by concatenating the partial scripts
  returned from both recursive calls, or by repeated string concatenation of
  output text, each of which can turn linear assembly into quadratic.
- Allocating a temporary buffer per output line, writing each line with a
  separate unbuffered write or flush, or formatting each line through a
  general-purpose formatter.
- Converting each line to an owned string just to look it up in the intern
  map; allocate only when a new id is created.
- Reading input line by line through a slow unbuffered stream, or reading
  content by looking at its text (a line `5`, `-x` or a single space is
  content, not a count or a tag).
