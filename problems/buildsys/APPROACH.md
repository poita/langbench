# buildsys: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `F` workspace files, `B` bytes of build-file text, `S` steps, `E`
declared inputs plus `after` and phony references, `R` steps in the reachable
set, `L` bytes a command reads or writes.

## Algorithm

A virtual file system (a map from path to content and its FNV-1a hash) lasts
the whole session. Each `build` lexes and parses the build files into syntax
trees and runs them with a tree-walking interpreter over a chain of lexical
scopes to produce the step list. The step graph is indexed by output, phony
name and source, checked for cycles with SPEC.md's depth-first search, and
`.kiln-state` is read into a map keyed by primary output. An event-driven
simulation runs the scheduler: ready steps are taken in serial order from
priority queues, and the clock jumps to the next completion. Commands run
against the virtual file system.

## Required rules

1. **Each distinct content of a file is hashed once.** `hash()`, freshness
   checks and the state lines reuse that hash across builds until the file
   changes.
2. **Every build evaluates afresh.** Nothing carries over between builds
   except the file system, its hashes and a glob index.
3. **`glob` is not a scan of every file.** It costs O(log F) plus the paths
   sharing the pattern's wildcard-free prefix, for example by binary search in
   a sorted index of the eligible paths. `filter` and `reject` match every
   element of their list.
4. **Copying a string or list is O(1); `a ++ b` is O(|a| + |b|)**, including in
   `set x = x ++ [y]`.
5. **A ready-set operation is O(log R)**; the scheduler never scans the ready
   set for the lowest serial.
6. **Commands are linear in their bytes**, except `sort_lines` (O(n log n)
   comparisons). `dedup` and `preprocess` use sets.

## Complexity

Lexing and parsing are O(B) per build. Graph construction and the cycle check
are O(S + E). Matching one path against a glob is O(pattern × path). One
build's scheduling is O(R log R + E), plus O(L) per command and O(entry size)
per freshness check. Hashing is O(content) once per distinct content.
