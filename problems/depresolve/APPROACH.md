# depresolve: required implementation approach

SPEC.md defines what the program must output. This note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of stdin and parse it in one pass into flat arrays: package names are
interned to dense integer ids, every version is packed into one integer key
that orders numerically, and every requirement becomes `(package id, lo, hi)`,
a half-open interval of version keys. Each package's versions are sorted newest
first, and each requirement's interval is then converted once into the
contiguous window of candidate indices it admits in that list. The search is the
SPEC's depth-first, newest-first, chronologically backtracking procedure run
iteratively: a frame stack of choice points, a `chosen` array indexed by package
id, and the pending requirement list kept as a persistent singly linked list in
an arena that is truncated on backtrack. Nothing is copied per step. On success
the chosen packages are sorted by name and written through one buffer.

## Required choices

1. **Dense integer package ids.** Intern each name to an id with one hash-map
   lookup during parsing; the map is never touched after parsing. All search
   state is indexed by id: `chosen` is an array of `P` entries (P = number of
   distinct names, at most 3000) holding the chosen version index or a "none"
   sentinel. No string hashing or string comparison happens inside the search.
2. **Versions as one packed integer key.** Encode `MAJOR.MINOR.PATCH` into a
   single 64-bit unsigned integer that compares like the version (for example
   21 bits per component, or base 1,000,001). The packing must also order the
   exclusive bounds that ranges produce, such as `(X+1).0.0` or `X.(Y+1).0`
   with a component of 1,000,001. Version comparison is then one integer
   comparison instead of a three-field or tuple comparison.
3. **Every range as one interval, resolved to an index window.** Parse `*`,
   exact, `^`, `~` and one to three comparators into a single half-open
   interval `[lo, hi)` of keys (intersecting the comparators while parsing; an
   empty interval yields no candidates). After all lines are read and each
   package's version list is sorted newest first, compute for every requirement
   the contiguous index window `[first, last)` of its admissible candidates with
   two binary searches, and store it with the requirement. An empty interval, or
   a package with no registry line, gives an empty window (`last <= first`;
   clamp so it reads as empty). Opening a choice point is then O(1): the frame
   stores this window and a cursor. Satisfied-rechecks against an already
   chosen package are one O(1) test (the chosen key against `lo`/`hi`, or the
   chosen index against the window). Total preprocessing is O(R log V) for R
   requirements and V versions per package; candidates are never filtered by a
   scan at search time.
4. **Requirements stored once, referenced by index.** All requirements of all
   lines live in one flat array; a version records the start and count of its
   slice. The pending list refers to requirements by index, never by copy.
5. **Pending list as a persistent linked list in an arena.** A cell is
   `(requirement index, next cell index)`. Choosing a version pushes its
   requirements, last first, as new cells in front of the current tail, so the
   tail ("rest") is shared and each frame can remember it as one integer.
   Each frame records the arena length when it was opened; backtracking to that
   frame truncates the arena to that length in O(1). Cost per choice is
   O(number of the version's requirements); no list is ever copied or spliced.
   There is one cell per requirement: a cell is consumed by moving to its
   `next`, never by allocating a replacement cell for the remainder of a slice.
   (A language whose natural building block is an immutable pair may use
   nested pairs instead of an arena; the sharing is the same.)
6. **Iterative search with an explicit frame stack.** Do not recurse. A frame
   holds the package id, the candidate cursor and window end, the rest-of-list
   cell index and the arena mark. The main loop pops one pending cell per step:
   chosen and satisfied → advance; chosen and violated → backtrack; not chosen
   and window empty → backtrack; otherwise push a frame, set `chosen`, and
   prepend the first candidate's requirements. Each step is O(1) plus the
   requirements prepended.
7. **Undo through the frame stack, not by copying `chosen`.** Under
   chronological backtracking a package is chosen exactly while its frame is on
   the stack, so undo is: on backtrack, reset `chosen[frame.pkg]` to "none",
   then either advance the frame's cursor (set `chosen`, truncate the arena,
   prepend the next candidate's requirements from the saved rest) or pop the
   frame and repeat. Total work is O(search steps + requirements prepended),
   matching the SPEC's step count; never copy or rebuild the chosen map.
8. **Hot state in locals.** Keep `chosen`, the arena, the frame stack and the
   pending-cell index in local variables of the search function (or one struct
   reached through a local reference), with the read-only registry arrays also
   bound to locals. Reserve the arena and frame stack up front or grow them by
   doubling.
9. **Input read in one go, parsed in one linear pass.** Read the whole input
   into one buffer and parse it in a single pass, either by walking it with an
   index (names as slices, numbers with a digit loop) or with the standard
   library's plain split on the fixed separators (`\n`, `:`, `, `, ` `) where
   that is the fastest idiomatic route. No regular expressions and no
   re-scanning of a line. Parsing is O(input size).
10. **Output once.** Collect the chosen package ids (the frames on the stack),
    sort them by name bytes (O(k log k) for k chosen packages), format each
    `name MAJOR.MINOR.PATCH` line into one buffer from the key (or from the
    stored version text) and write it with a single write or one buffered
    writer flushed once.

## Left to the implementer

- The exact key packing (bit fields or decimal radix) and the sentinel used for
  "not chosen" (an index of -1, a key of all ones, and so on).
- Whether a frame's cursor counts up through a newest-first list or down
  through an oldest-first list, and whether the per-requirement window is
  stored inline in the requirement record or in a parallel array.
- Struct layout, integer widths (32-bit indices are sufficient), container
  types, naming and module structure; whether parsing helpers are separate
  functions.
- Arena and stack initial capacities.
- Whether undoing `chosen` uses the frame's package (rule 7) or a separate
  trail of chosen ids truncated to a mark saved in the frame; both are O(1)
  per undone choice.
- Micro-optimisations that keep the structure: caching the chosen key alongside
  the index, keeping the original version text for output, skipping the
  sort for single-version packages.
- Compiler flags beyond a normal optimised release build.

## Pitfalls

- Keeping the hot search state (pending storage, `chosen`, the trail, the
  requirement array) in module-level or global mutable variables. In languages
  where globals are thread-local by default, every access goes through a
  thread-local lookup, which in the search loop costs several times more than
  the resolver work itself. Use locals or a struct passed by reference.
- Keeping pending as an array stack that is overwritten in place and restored
  from an undo log of overwritten slots: it doubles the memory traffic of every
  push compared with the persistent list of rule 5 and is not the required
  structure.
- Recursing as in the SPEC pseudocode: depths beyond 10,000 overflow default
  stacks, and per-call overhead dominates millions of short steps.
- Copying the `chosen` map or the pending list at each choice point (the
  value semantics of the pseudocode taken literally), which makes every step
  O(P) or O(pending length) instead of O(1).
- Representing pending as a contiguous array and inserting at the front,
  shifting the whole remainder on every choice.
- Filtering candidates at search time by scanning the version list (even from
  a cursor, skipping versions outside the range), binary-searching per choice
  point instead of using the precomputed window, re-evaluating comparator
  lists, or comparing versions as tuples or strings inside the loop.
- Building a fresh candidate list per choice point instead of storing a window
  into the sorted version list.
- Looking up packages by name (hashing strings) during the search, or storing
  `chosen` as a hash map keyed by name.
- Recomputing the sorted order of versions, or re-parsing range text, after
  parsing.
- Writing output one unbuffered line or field at a time.
