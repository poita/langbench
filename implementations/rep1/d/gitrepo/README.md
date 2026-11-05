# gitrepo

A small D library and command-line tool that read a git repository straight
off disk — without `git`, without a zlib or SHA-1 library. The object database,
DEFLATE decompression, SHA-1, pack index/pack file parsing, delta
reconstruction, refs and git's revision syntax are all implemented here, using
only the D standard library for file I/O and containers.

It answers six queries: `log`, `ls-tree`, `cat-file`, `diff`, `rev-parse` and
`count-objects`.

## Layout

| path | contents |
|---|---|
| `source/gitrepo/` | the library, one module per responsibility (below) |
| `cli/main.d` | the thin command-line front end |
| `tests/unit/` | unit tests (`dub test`), separate from the library source |
| `dub.sdl` | package manifest: configurations `application`, `library`, `unittest` |
| `build.sh`, `run.sh` | build and run helpers |

Library modules:

| module | role |
|---|---|
| `gitrepo.sha1` | SHA-1 (FIPS 180-4) |
| `gitrepo.inflate` | zlib/DEFLATE decoder with two-level Huffman tables |
| `gitrepo.delta` | git delta application |
| `gitrepo.pack` | pack index v2 lookup, object types |
| `gitrepo.odb` | object store: loose objects, packs, `OFS_DELTA`/`REF_DELTA`, caches |
| `gitrepo.objects` | commit, tree and tag parsing |
| `gitrepo.refs` | `HEAD`, loose refs, `packed-refs` |
| `gitrepo.revision` | revision syntax (`^`, `~`, `^{...}`, abbreviations) |
| `gitrepo.repository` | `Repository`: facade with parsed-object caches and history walk |
| `gitrepo.queries` | the six queries, `execute()` dispatcher, tree flatten/diff |
| `gitrepo.quote` | git's default path quoting |
| `gitrepo.batch` | `commands.txt` → `NNN.out` driver used by the CLI |
| `gitrepo` | `package.d`: imports everything above |

## Building

Requires LDC and dub.

```
./build.sh          # dub build -b release --compiler=ldc2 --config=application
```

This produces `bin/gitrepo`. `./run.sh` runs it from any directory.

Unit tests:

```
dub test --compiler=ldc2
```

## Command-line usage

```
gitrepo <input dir> <output dir>
```

`<input dir>` holds `repo/` (a `.git` directory or bare repository) and
`commands.txt` with one command per line. For command *k* the tool writes
`<output dir>/NNN.out` (`001.out`, `002.out`, …). A command that fails
(unknown command, bad arguments, unresolvable revision, missing or damaged
object) produces a file containing just `error`; the exit status is still 0.

Commands (tokens are separated by single spaces; empty tokens are invalid):

| command | output |
|---|---|
| `log <rev> [<n>]` | `<id> <author> <author time> <subject>` per commit, newest committer date first |
| `ls-tree <rev> [<path>]` | `<mode> <type> <id>\t<name>` per entry |
| `cat-file <rev>` | `<type> <size>\n` then the verified payload |
| `diff <rev1> <rev2>` | `:<mode1> <mode2> <id1> <id2> <A\|D\|M\|T>\t<path>` per changed path |
| `rev-parse <rev>` | the 40-digit id |
| `count-objects` | `loose:`, `in-pack:` and `packs:` counts |

Example:

```
$ cat in/commands.txt
count-objects
rev-parse main~1
log main 2
$ ./run.sh in out
$ cat out/003.out
bc99f2827e555cad8970b6d96d3c0cf224336304 Ada Lovelace 1400003600 Add only.txt
0f5efe1e004bb7db3eed8d431f1dd464c55070b7 Ada Lovelace 1400000000 Empty tree commit
```

## Library usage

```d
import std.stdio;
import gitrepo;

void main()
{
    // One Repository per process: packs are read once and every decoded
    // object, commit and tree is cached.
    auto repo = new Repository("project/.git");

    // Revision syntax: names, abbreviations, ^, ~ and ^{...}
    ObjectId head = repo.revParse("HEAD");
    ObjectId parent = repo.revParse("HEAD~1");

    // History in git's default order
    foreach (entry; repo.log(head, 5))
        writeln(entry.id, " ", entry.commit.authorName, ": ", entry.commit.subject);

    // Trees
    foreach (e; repo.tree(repo.peel(head, ObjectType.tree)).entries)
        writeln(e.mode, " ", e.name, " ", e.id);

    // Verified object content (SHA-1 of the stored form must equal the id)
    auto obj = repo.readVerified(head);
    writeln(typeName(obj.type), " of ", obj.data.length, " bytes");

    // Whole queries return the exact bytes the CLI writes
    auto bytes = execute(repo, "diff HEAD~1 HEAD");
    write(cast(string) bytes);

    // Failures are GitError exceptions
    try
        repo.revParse("no-such-branch");
    catch (GitError e)
        writeln("failed: ", e.msg);
}
```

The low-level pieces are usable on their own too: `Inflater.decompress` for
zlib streams, `applyDelta` for git deltas, `Sha1`/`sha1Of` for hashing, and
`ObjectStore` for raw object access.

## Notes

- Ref names, paths, author names and messages are carried through as raw bytes.
- The Adler-32 trailer of zlib streams is not verified; damaged streams are
  caught by header checks and, for `cat-file`, by the SHA-1 comparison.
- Only the repository's `HEAD`, `refs/`, `packed-refs` and `objects/` are read.
