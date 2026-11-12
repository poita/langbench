# gitrepo

A small C++20 library and command-line tool that reads a git repository
straight off disk — loose objects, packfiles (with `OFS_DELTA` / `REF_DELTA`),
refs, `packed-refs` and git's revision syntax — and answers `log`, `ls-tree`,
`cat-file`, `diff`, `rev-parse` and `count-objects` queries.

Everything is implemented from scratch on top of the standard library: SHA-1,
zlib/DEFLATE decompression, pack index lookup and delta reconstruction. It does
not call `git` and uses no git, zlib or hashing library.

## Layout

| path | contents |
|---|---|
| `include/gitrepo/` | public headers (one per module) |
| `src/` | library implementation |
| `cli/main.cpp` | the command-line tool (file I/O only; all logic is in the library) |
| `tests/` | GoogleTest unit and integration tests; they build throw-away repositories on the fly |

Library modules:

- `sha1.hpp` – incremental SHA-1.
- `inflate.hpp` – `zlib_inflate`, RFC 1950/1951 decoder that finds the end of the stream by decoding it.
- `object_store.hpp` – loose objects, pack index v2 (`PackIndex`), packfiles, delta chains (`apply_delta`), abbreviated-id lookup by binary search. Pack objects are cached once decoded.
- `objects.hpp` – parsers for commits, trees and tags.
- `refs.hpp` – `HEAD`, loose refs, `packed-refs`, symbolic refs.
- `revision.hpp` – `resolve_revision` (`main~2^2`, `v1^{tree}`, `1a2b3c`, …) and `peel`.
- `repository.hpp` – ties the above together and caches parsed commits and trees.
- `quote.hpp` – git's C-style path quoting.
- `commands.hpp` – the six queries as `run_command(repo, "log main 5")`.

## Building

Requires a C++20 compiler and CMake ≥ 3.20; the tests need GoogleTest.

```sh
./build.sh          # Release build into ./build
(cd build && ctest) # run the unit tests
```

or by hand:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Pass `-DGITREPO_BUILD_TESTS=OFF` to skip the tests (and the GoogleTest dependency).

## Command-line use

```sh
./run.sh <input path> <output dir>
```

`<input path>` holds `repo/` (a `.git` directory or bare repository) and
`commands.txt` with one query per line. Line *k* is answered in
`<output dir>/NNN.out` (`001.out`, `002.out`, …). A query that fails writes
`error`. Commands (arguments are separated by single spaces):

| command | output |
|---|---|
| `log <rev> [<n>]` | `<id> <author> <author time> <subject>` per commit, newest committer date first |
| `ls-tree <rev> [<path>]` | `<mode> <type> <id>\t<name>` per entry of the tree |
| `cat-file <rev>` | `<type> <size>\n` then the payload; the SHA-1 is verified |
| `diff <rev1> <rev2>` | raw `:<mode1> <mode2> <id1> <id2> <status>\t<path>` lines, recursive |
| `rev-parse <rev>` | the 40-digit object id |
| `count-objects` | `loose:`, `in-pack:` and `packs:` counts |

The exit status is 0 whenever the output could be produced, even if individual
commands failed.

## Using the library

```cpp
#include <iostream>
#include "gitrepo/commands.hpp"
#include "gitrepo/repository.hpp"
#include "gitrepo/revision.hpp"

int main() {
  gitrepo::Repository repo("/path/to/project/.git");

  // Resolve a revision and inspect the commit.
  gitrepo::ObjectId id = gitrepo::resolve_revision(repo, "main~3");
  const gitrepo::Commit& c = repo.commit(id);
  std::cout << id.hex() << " " << c.author.name << ": " << c.subject << "\n";

  // Walk a tree.
  gitrepo::ObjectId tree = gitrepo::peel(repo, id, gitrepo::PeelTarget::Tree);
  for (const auto& e : repo.tree(tree).entries) {
    std::cout << std::oct << e.mode << std::dec << " " << e.name << "\n";
  }

  // Or run one of the CLI queries; failures throw gitrepo::Error.
  std::cout << gitrepo::run_command(repo, "log main 5");
}
```

Link against the `gitrepo::gitrepo` target (e.g. with `add_subdirectory`) and
catch `gitrepo::Error` for missing or damaged objects and unresolvable
revisions.

## Notes

- The Adler-32 trailer of every zlib stream is verified; a pack entry's
  decompressed size and a delta's declared base and result sizes must match.
- A `Repository` reads the loose-object listing, pack indexes and packs once,
  when it is constructed; it is not thread-safe.
