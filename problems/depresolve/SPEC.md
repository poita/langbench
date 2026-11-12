# depresolve — Package dependency resolver

Given a package registry (every version of every package, each with its
list of dependency requirements) and a root manifest, pick exactly one
version for every package that is needed, such that every requirement of the
root and of every picked version is satisfied by the picked version of its
target. The search order is fully specified below (depth-first, newest
version first, chronological backtracking) so that every correct
implementation prints the same resolution; when no resolution exists at all,
print `unsatisfiable`.

## Input

Standard input is ASCII text: zero or more **registry lines** followed by
exactly one **root line**, which is the last line of the input. Every line,
including the last, ends with a single `\n` (byte 0x0A); there are no `\r`
bytes, no blank lines, no comments, no leading or trailing blanks and no
byte-order mark.

```
input         = { registry_line } root_line
registry_line = name " " version ":" requirements "\n"
root_line     = "root:" requirements "\n"
requirements  = ""  |  " " requirement { ", " requirement }
requirement   = name " " range
name          = [a-z] [a-z0-9-]*
version       = num "." num "." num
num           = "0" | [1-9] [0-9]*
range         = "*" | version | "^" version | "~" version
              | comparator { " " comparator }
comparator    = ( "<" | "<=" | ">" | ">=" ) version
```

- A registry line declares one **package version** and its requirements.
  `name` is the package name; `version` is a semantic version
  `MAJOR.MINOR.PATCH` of three non-negative decimal integers without leading
  zeros (no prerelease or build suffixes). Every component is at most
  1,000,000, so the numbers fit in 32-bit integers, but components must be
  compared **numerically** (`1.10.0` is newer than `1.9.0`).
- Separators are exact: one space between name and version, a colon
  directly after the version, then either nothing (the package version has
  no requirements: the line ends right after the `:`) or one space followed
  by the requirements separated by a comma and one space. Within a
  requirement the name and the range are separated by one space, and within
  a comparator range the comparators are separated by one space. There is no
  space between a comparator's operator and its version, nor after `^`/`~`.
- The same `name version` pair never appears on two registry lines. The
  versions of one package may appear in any order and may be interleaved
  with other packages' lines. Package names are between 1 and 16 characters
  and the name `root` never occurs as a package name, neither at the start
  of a registry line nor inside a requirement.
- The requirements on one line (the root line included) name **distinct**
  packages. A requirement may name a package that has no registry line at
  all (then no version can satisfy it). Dependency cycles are allowed,
  including a package version that requires its own package.
- The root line is always present and always last. `root:` with no
  requirements is a valid manifest that needs nothing.

Inputs are always well formed; no error handling is required.

### Range semantics

Let `v` be a version and compare versions numerically component by
component (major first, then minor, then patch). A range accepts `v` when:

| range | accepts `v` when |
|---|---|
| `*` | always |
| `X.Y.Z` (exact) | `v == X.Y.Z` |
| `^X.Y.Z`, `X > 0` | `X.Y.Z <= v < (X+1).0.0` |
| `^0.Y.Z`, `Y > 0` | `0.Y.Z <= v < 0.(Y+1).0` |
| `^0.0.Z` | `0.0.Z <= v < 0.0.(Z+1)` (only `0.0.Z` itself) |
| `~X.Y.Z` | `X.Y.Z <= v < X.(Y+1).0` (for every `X`, including 0) |
| `<A`, `<=A`, `>A`, `>=A` | the comparison holds; with several comparators **all** must hold |

These are the npm semantics for caret and tilde: caret keeps the leftmost
non-zero component fixed (`^0.2.3` is `>=0.2.3 <0.3.0`, `^0.0.3` accepts
only `0.0.3`), tilde always keeps major and minor fixed (`~0.0.3` is
`>=0.0.3 <0.1.0`). A comparator range has one to three comparators; it may
be empty in effect (e.g. `>=2.0.0 <1.0.0`), in which case nothing satisfies
it.

## The resolution algorithm

The output is defined as the **first** complete solution found by the
following search. Implementations must reproduce this order exactly; any
other valid resolution is rejected.

```
function resolve(pending, chosen):
    # pending: an ordered list of requirements (name, range)
    # chosen:  a map from package name to the version picked for it
    if pending is empty:
        return chosen                                   # success
    (name, range) = first element of pending
    rest = pending without its first element
    if name is in chosen:
        if chosen[name] satisfies range:
            return resolve(rest, chosen)
        return FAIL
    candidates = every version of name in the registry that satisfies range,
                 ordered from newest to oldest
    for version in candidates:                          # newest first
        result = resolve(requirements(name, version) ++ rest,
                         chosen with name -> version added)
        if result is not FAIL:
            return result
    return FAIL

answer = resolve(requirements of the root line, in the order listed, {})
```

`requirements(name, version)` is the requirement list of that registry line
in the order written, and `++` is list concatenation: a newly chosen
version's requirements are placed **in front of** the remaining pending
requirements, which makes the search depth-first in the order the
requirements are listed. `chosen` is treated as a value: returning `FAIL`
from a call discards everything that call added, so backtracking is
chronological — when a requirement cannot be met, the most recently chosen
package that still has an untried candidate moves to its next-newest
candidate, even if that package is unrelated to the failing requirement. A
requirement naming a package that is absent from the registry, or a range
that no version satisfies, simply yields an empty candidate list.

Consequences worth noting:

- The version chosen for a package is fixed by the **first** requirement of
  that package the search reaches; later requirements are only checked
  against it (and trigger backtracking if they fail).
- Only packages actually reached through chosen versions end up in
  `chosen`; the requirements of versions that were not chosen are irrelevant.
- The result is the first solution in search order, not a globally
  "maximal" one: in the second example below, `a 1.0.0` + `b 2.0.0` would
  also be a valid set, but the search returns `a 2.0.0` + `b 1.0.5`.
- The search can take exponential time on adversarial inputs; the test
  suite is constructed so that this exact search takes at most a few
  million steps (see Input sizes). Smarter search strategies are only
  acceptable if they provably return the same first solution.
- The recursion depth of the formulation above equals the number of
  requirements processed along the current path (satisfied re-checks of an
  already chosen package included). It reaches 3,001 on the 3000-package
  chain and about 9,300 on the largest registry (hundreds of chosen
  packages with up to 40 requirements each), so a naive recursive
  implementation needs a call stack of well over 10,000 frames. Use an
  explicit stack or make sure the call stack is big enough.

## Output

If the search succeeds, print one line `name version` for every package in
`chosen` — the name, one space, the chosen version as `MAJOR.MINOR.PATCH`
exactly as written in the registry — sorted by name in ascending byte order
(`-` sorts before digits, which sort before letters: `my-lib` < `my-lib2` <
`mylib`). Each line ends with `\n`. When the root has no requirements the
output is empty (zero bytes).

If the search fails, print exactly:

```
unsatisfiable
```

Nothing else may be printed on stdout. Exit with status 0 in both cases.

## Examples

### 1. Diamond that needs backtracking

Input:

```
a 1.0.0: c ^1.0.0
b 1.0.0: c ~1.2.0
c 1.1.0:
c 1.2.5:
c 1.3.0:
root: a *, b *
```

Trace: pending `[a *, b *]` → choose `a 1.0.0`, pending `[c ^1.0.0, b *]` →
candidates for `c` are `1.3.0, 1.2.5, 1.1.0`; choose `c 1.3.0`, pending
`[b *]` → choose `b 1.0.0`, pending `[c ~1.2.0]` → `c` is already `1.3.0`,
which does not satisfy `~1.2.0` → FAIL → `b` has no other candidate → FAIL →
`c` moves to its next candidate `1.2.5`, pending `[b *]` → `b 1.0.0`,
pending `[c ~1.2.0]` → satisfied → pending empty → success.

Output:

```
a 1.0.0
b 1.0.0
c 1.2.5
```

### 2. First solution, not the globally newest set

Input:

```
a 2.0.0: b ~1.0.0
a 1.0.0:
b 1.0.0:
b 1.0.5:
b 1.5.0:
b 2.0.0:
root: a *, b *
```

`a 2.0.0` is chosen first; its requirement `b ~1.0.0` is then in front of
the root's `b *`, so `b` is fixed to `1.0.5` (the newest of `1.0.5, 1.0.0`),
and the root's `b *` is satisfied by it.

Output:

```
a 2.0.0
b 1.0.5
```

### 3. Conflicting majors

Input:

```
a 1.0.0: c ^1.0.0
b 1.0.0: c ^2.0.0
c 1.0.0:
c 2.0.0:
root: a *, b *
```

`c` is fixed to `1.0.0` by `a`, then `b` requires `c ^2.0.0`; backtracking
finds no alternative for `b`, `c` or `a`.

Output:

```
unsatisfiable
```

### 4. Order of requirements matters

With the registry

```
a 2.0.0: c ^2.0.0
a 1.0.0: c ^1.0.0
b 2.0.0: c ^1.0.0
b 1.0.0: c ^2.0.0
c 1.0.0:
c 2.0.0:
```

the root line `root: a *, b *` resolves to `a 2.0.0`, `b 1.0.0`, `c 2.0.0`
(`a 2.0.0` fixes `c 2.0.0`; `b 2.0.0` fails, `b 1.0.0` fits), while
`root: b *, a *` resolves to `a 1.0.0`, `b 2.0.0`, `c 1.0.0`.

## Checking

Output is checked by `verify.py`. It rejects anything that is not either
the single line `unsatisfiable` or a list of `name version` lines in
strictly increasing name order; it then independently checks that every
listed package version exists in the registry, that every requirement of the
root and of every listed version is satisfied by the listed version of its
target, that every listed package is reachable from the root through listed
versions and that nothing else is listed; and finally it requires the
resolution to be exactly the one the specified search produces
(`unsatisfiable` is accepted only when the search really fails). Trailing
whitespace on a line and trailing blank lines are tolerated.

## Input sizes

Across the test suite: at most 3000 distinct packages, at most 12,001 input
lines, at most 1600 versions of one package, at most 40 requirements on one
line, names of at most 16 characters, version components at most
1,000,000, and inputs of at most 3 MB. The largest registries have 500
packages with 20 versions each and up to 40 requirements per line (about
10,000 lines); one test is a dependency chain 3000 packages deep whose tail
has to be retried from the root.

Several tests require substantial backtracking: stepping down through many
versions of one package, rebuilding whole subtrees after a late conflict,
enumerating tens of thousands of combinations before the first solution,
unwinding a fully built 500-package lockfile-style tree whose last root
requirement conflicts, and exhaustive failure on unsatisfiable random
registries. The heaviest test opens about 2.6 million choice points (about
four million search steps).
