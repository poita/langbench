# buildsys: implementation approach

SPEC.md defines what Kiln does. This note fixes how it is done. Where the two
seem to conflict, SPEC.md wins.

Sizes used below: `F` files in the workspace, `B` bytes of build-file text, `S`
steps, `E` declared inputs plus `after` and phony references, `R` steps in the
reachable set, `L` bytes of file content a command reads or writes.

## Overall approach

There is one in-memory virtual file system for the whole session. Each file
holds immutable content and a cached FNV-1a hash. For every `build`, the build
files are lexed and parsed into an AST, and a tree-walking interpreter runs that
AST to produce the step list. Graph construction then resolves references
through hash maps, the iterative DFS from the spec checks for cycles, and
`.kiln-state` is parsed into a map keyed by primary output. An event-driven
simulation (ready min-heaps plus an array of workers) runs the scheduler and
executes commands in-process against the VFS. The log is accumulated in one
growable buffer. At the end of the session, the workspace is written out once.

## Required choices

1. **The VFS is a hash map from path to file record.** A file record holds the
   content as an immutable byte buffer that can be shared, plus a cached 64-bit
   hash and a flag saying whether the hash is valid. Writes replace the buffer;
   reads hand out a reference to it and never copy it. Commands therefore
   capture their inputs at start time in O(1) per input. The VFS, its hashes
   and the glob index below are the only data that live across builds.
2. **Content hashes persist across builds.** A file's hash is computed at most
   once per distinct content. It stays valid across builds until a session
   `edit`/`create`/`delete` or a command output replaces that file. A command
   output is hashed once, when it is written, and that one hash serves both the
   state entry and later freshness checks. Other writes (session steps, the
   state file itself) just mark the hash invalid; it is computed on first use. The `hash()` command and the `in`,
   `dep` and `out` state lines all reuse the cached value. Rehashing every input
   on every build makes FNV-1a the dominant cost of incremental sessions.
3. **There is a sorted glob index with literal-prefix narrowing.** Keep a sorted
   list of the glob-eligible paths, meaning every path except those under `out/`
   and `.kiln-state`. Rebuild it lazily at most once per build, and only when
   the set of eligible paths has changed. Commands write only under `out/`, so
   it never changes during evaluation. For `glob(p)`, take the leading pattern
   components that contain no `*`, `?` or `[`, join them with `/`, and
   binary-search the index for the range of paths that start with that byte
   prefix. Run the full matcher only on that range. The result is already
   sorted. The cost is O(log F + candidates in range) instead of O(F) per call.
   The prefix has no trailing `/`, because `src/**` also matches the path
   `src` itself; extra paths such as `srcx` in the range are rejected by the
   matcher. A pattern with no literal leading component (`**`, `*/x`) scans
   the whole index. `filter` and `reject` take lists, not the index, so they
   always run the matcher on every element.
4. **Each glob, filter or reject call compiles its pattern once.** Compile the
   pattern into per-component item arrays (literal byte, `?`, `*`, or class as
   ranges plus a negate flag) and a `**` marker. Malformed patterns are rejected
   during this compile step.
5. **The glob matcher does not allocate per candidate.** Walk the candidate's
   components through `/` offsets instead of splitting it into new strings.
   Within one component, match with the standard linear star-backtracking
   algorithm: remember the last `*` and retry from there. Handle `**` either by
   backtracking over component boundaries or with a small memo indexed by
   (pattern component, candidate component), held in reusable scratch storage.
   Do not build a full byte-level DP table for each component.
6. **Each build parses once and then interprets.** Each build-file text is lexed
   and parsed exactly once each time it is included. That parse covers the
   string-interpolation templates and the rule bodies, so evaluating them never
   re-scans source text. Then a recursive tree walk interprets the AST. Rule
   definitions keep a reference to their AST and their captured scope. Nothing
   is cached across builds except the VFS (contents, hashes, glob index): no
   ASTs, no evaluation results and no parsed state carry over, because SPEC
   requires a fresh evaluation and a fresh state read for every build.
7. **Copying a value is O(1).** Strings are immutable byte strings that copy as a
   handle (shared, reference-counted or slice). Lists are immutable arrays of
   such values, also shared by handle. `a ++ b` allocates one new array of
   `|a|+|b|` handles and never deep-copies strings or nested lists. It always
   allocates, even for `set x = x ++ [y]`: no in-place append when the old
   list is unshared, so list-growing loops cost the same O(n²) handle copies
   in every implementation. Building a
   string (interpolation, `~`, `join`, `replace`) goes into one growable buffer.
8. **Scopes are hash maps with a parent link, and built-ins are looked up by
   hash map or are resolved at parse time.** Name lookup walks the scope chain,
   doing an O(1) map probe at each level. Built-in functions, commands and rules
   are found with a hash-map lookup, or resolved to an index while parsing. They
   are never found by comparing the name against a chain of strings on every
   call.
9. **The graph is built with hash maps in O(S + E).** Map output paths to step
   indices, phony names to nodes and source paths to nodes. Build each node's
   successor list with first-occurrence de-duplication in linear time, using a
   per-node "seen" mark or set. The cycle check and the reachable set use the
   spec's iterative DFS with an explicit stack, never recursion. Each step's
   canonical command string is rendered once, when the step is created.
10. **The state file is parsed and written in one pass each.** Parse
    `.kiln-state` in a single linear scan over its lines, with no regular
    expressions and no splitting of the whole file into intermediate copies
    beyond one line view at a time. The result is a hash map from primary
    output to an entry holding `cmd` plus `(path, hash)` lists, with hashes
    stored as 64-bit integers. To write the file, sort the keys once and emit
    everything into one buffer.
11. **The scheduler is event-driven, with min-heaps or ordered sets as the
    ready set.** `pending` counters and dependent lists are arrays indexed by
    node. The ready set is two min-heaps (or ordered sets) keyed by step
    serial: one for steps with no freshness decision yet and one for steps
    decided stale. Phase (A) pops the undecided heap in serial order until it
    is empty: a fresh step completes immediately (pushing newly ready steps
    onto the undecided heap), and a stale step moves to the stale heap. Phase
    (B) dispatches from the stale heap, which after (A) holds every ready
    step; its leftovers stay there for the next instant. Each step is pushed
    and popped O(1) times per build. Free workers are found by lowest
    id; a scan over at most 64 workers is fine. Time advances to the minimum
    `end` among running workers. One build therefore costs O(R log R + E) plus
    the cost of the commands. A freshness check is O(entry size) with hash
    lookups.
12. **Every command runs in linear time over its bytes.** Split input into lines
    as views or offsets, without copying each line. Write output into one
    preallocated or growable buffer. `dedup` uses a hash set of lines,
    `sort_lines` is a byte-order sort (O(n log n)), and `grep` and `replace` use
    a linear substring search. `count_lines` counts `0x0A` bytes directly.
    `preprocess` expands recursively into a single output buffer and checks for
    cycles against the need stack, which is at most a few levels deep. It
    collects the discovered set in a hash set and sorts that set once. For each
    step, input and `dep` hashes come from the VFS cache and output hashes are
    computed once.
13. **I/O happens in bulk at the edges.** Read each input file once at startup.
    Build the log in memory and write it with one call. When writing the final
    workspace, create each distinct directory once (remember which ones exist
    already) and write each file with a single write. Do not call a recursive
    "create directories" routine again for every file.

## Left to the implementer

- The concrete containers: an ordered map instead of hash map plus sorted
  index for the VFS is acceptable if prefix range lookup stays logarithmic. The
  hash function for internal maps, and whether paths are interned to integer
  ids, are also free choices.
- The layout of AST nodes, values and records. Whether variables are resolved
  to slots at parse time. The memo strategy for `**`, whether compiled patterns
  are cached within a build, and the layout of character classes (a range list
  or a 256-bit set).
- Module structure, naming, error plumbing (exceptions or result values) and
  log formatting helpers.
- Memory management: an arena or pooling for per-build data, and small
  micro-optimisations such as reserving capacity, faster hex formatting and
  avoiding bounds checks.
- How the event list is ordered for the log, provided the result matches the
  spec.
- Whether a command's result is computed at dispatch (from the inputs it
  captures then, applied at its end time) or at its end time from the inputs
  captured at dispatch.

## Pitfalls

- Rehashing file contents on every build, or on every freshness check, instead
  of caching the hash on the file record.
- Matching every glob against all `F` workspace paths when the pattern starts
  with literal components. Re-sorting the path list on every `glob` call.
- Splitting each glob candidate into a freshly allocated array of component
  strings, or allocating DP tables or vectors, per candidate or per component.
  Under a garbage collector or `malloc`, this per-candidate garbage costs more
  than the matching itself.
- A value type that holds a by-value string and deep-copies it on every
  variable read, function argument, list element copy or `++`. KBL programs that
  grow lists with `set x = x ++ [...]` then copy every string they hold over and
  over.
- Finding the minimum-serial ready step by a linear scan of an unsorted array,
  then removing it by search and shift, or keeping decided-stale steps in the
  same heap as undecided ones so that every instant re-pops them. This is O(R²) per build when hundreds
  of steps become ready at once, which happens on every incremental build.
- Looking up built-in functions by comparing the name against each entry in a
  list, on every call.
- Parsing the state file by splitting it into a fresh array of line strings and
  then re-splitting each line. Validating hashes or paths with regular
  expressions.
- Copying file contents into each command's input instead of sharing the
  immutable buffer. Building command output by repeated string concatenation
  in a loop when the language's strings are immutable.
- Creating the full directory chain for every output file, or opening each
  file through a buffered stream with default small buffers, when the session
  ends by writing thousands of files.
