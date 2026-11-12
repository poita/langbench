# gitrepo

A small, dependency-free Rust library and command-line tool that reads a git
repository straight off disk. It never runs `git` and uses no git, zlib or
SHA-1 crate: SHA-1, DEFLATE/zlib decoding, pack-index lookup, delta
reconstruction, ref resolution and git's revision syntax (`HEAD~2`,
`v1.0^{tree}`, `main^2`, abbreviated ids, ...) are all implemented here using
only the standard library.

It understands:

* loose objects and version-2 packfiles with their `.idx` files, including
  `OFS_DELTA` and `REF_DELTA` chains (bases may be in another pack or loose);
* `HEAD`, loose refs, symbolic refs and `packed-refs`;
* commits, trees and annotated tags.

## Building

```sh
cargo build --release          # or ./build.sh
cargo test                     # unit and integration tests
```

The binary is `target/release/gitrepo`; `./run.sh` is a thin wrapper around it.

## Command-line use

```
gitrepo <input dir> <output dir>
```

`<input dir>` contains `repo/` (the contents of a `.git` directory, or a bare
repository) and `commands.txt`, one query per line (tokens separated by single
spaces; an empty token makes the command invalid). For the command on line *k*
the tool writes `<output dir>/NNN.out` (`001`, `002`, ...). A command that
cannot be carried out writes `error`; the exit status is 0 regardless.

| command | output |
|---|---|
| `log <rev> [<n>]` | `<id> <author> <author time> <subject>` per commit, newest committer date first, at most `n` lines |
| `ls-tree <rev> [<path>]` | `<mode> <type> <id>\t<name>` for each entry of the tree (or subtree) |
| `cat-file <rev>` | `<type> <size>\n` and the payload, after verifying its SHA-1 |
| `diff <rev1> <rev2>` | raw recursive tree diff: `:<mode1> <mode2> <id1> <id2> <A\|D\|M\|T>\t<path>` |
| `rev-parse <rev>` | the 40-digit id `<rev>` resolves to |
| `count-objects` | `loose:`, `in-pack:` and `packs:` counts |

Example:

```sh
$ cat in/commands.txt
count-objects
log main 2
ls-tree main src
$ gitrepo in out && cat out/002.out
bc99f2827e555cad8970b6d96d3c0cf224336304 Ada Lovelace 1400003600 Add only.txt
0f5efe1e004bb7db3eed8d431f1dd464c55070b7 Ada Lovelace 1400000000 Empty tree commit
```

Names, authors and messages are handled as raw bytes and need not be UTF-8.

## Library use

```rust
use std::path::Path;
use gitrepo::{commands, rev, Repository};

fn main() -> gitrepo::Result<()> {
    let repo = Repository::open(Path::new("path/to/.git"))?;

    // Resolve a revision and inspect the commit.
    let id = rev::resolve(&repo, b"HEAD~1")?;
    let commit = repo.commit(&id)?;
    println!("{id} {}", String::from_utf8_lossy(&commit.subject()));

    // Read a tree and verify an object against its id.
    for entry in repo.tree(&commit.tree.unwrap())?.iter() {
        println!("{:06o} {}", entry.mode, String::from_utf8_lossy(&entry.name));
    }
    repo.read_verified(&id)?;

    // Or run one of the CLI queries and get its exact output bytes.
    let out = commands::execute(&repo, b"log HEAD 5")?;
    print!("{}", String::from_utf8_lossy(&out));
    Ok(())
}
```

## Layout

| module | responsibility |
|---|---|
| `sha1` | SHA-1 hasher and object hashing |
| `inflate` | DEFLATE + zlib decoder |
| `delta` | git delta application |
| `pack` | pack index v2 lookup and pack entry decoding |
| `store` | loose + packed object database with caching, abbreviation lookup |
| `object` | commit, tree and tag parsing; subject extraction |
| `refs`, `rev` | ref files, `packed-refs`, revision syntax and peeling |
| `repo` | `Repository`: store + refs + parsed-object caches |
| `commands`, `quote` | the six queries and git path quoting |

Objects are decoded at most once per `Repository` (delta bases included),
abbreviated ids are resolved by binary search, `log` uses a priority queue,
and `cat-file` always verifies the SHA-1. The Adler-32 trailer of zlib
streams is not checked; the object hash covers that.

A `Repository` uses interior mutability for its caches and is therefore not
`Sync`.
