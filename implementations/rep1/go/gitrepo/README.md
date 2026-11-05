# gitrepo

`gitrepo` reads a git repository straight off disk — loose objects,
packfiles, refs — and answers queries about it. It is a Go library plus a thin
command-line tool. Everything is implemented from scratch with the standard
library only: the SHA-1 routine, the DEFLATE/zlib decoder, pack index and
packfile parsing, delta reconstruction, ref and revision resolution. It never
runs `git` and never writes to the repository.

## Layout

| Path | Responsibility |
|---|---|
| `sha1/` | SHA-1 (FIPS 180-4), streaming |
| `inflate/` | table-driven DEFLATE + zlib wrapper decoder |
| `store.go`, `pack.go` | object store: loose objects, `.idx` v2 / `.pack` v2, `OFS_DELTA` / `REF_DELTA`, caches |
| `object.go` | commit, tree and tag parsing |
| `refs.go`, `rev.go` | `HEAD`, loose refs, `packed-refs`; `^`, `~`, `^{...}`, abbreviated ids |
| `log.go`, `tree.go`, `quote.go` | history walk (binary heap), tree lookup and diff, path quoting |
| `exec.go` | the query language (`log`, `ls-tree`, `cat-file`, `diff`, `rev-parse`, `count-objects`) |
| `cmd/gitrepo/` | the command-line tool |

## Build

Requires Go 1.27 or newer.

```
./build.sh          # writes bin/gitrepo
go test ./...       # unit tests
```

## Command-line use

```
./run.sh <input dir> <output dir>
```

`<input dir>` contains `repo/` (a `.git` directory or bare repository) and
`commands.txt` (one query per line, split on single spaces). For line *k* the
answer is written to `<output dir>/NNN.out` (`001.out`, `002.out`, …). A query
that fails writes `error` and the exit status is still 0.

| Query | Output |
|---|---|
| `log <rev> [<n>]` | `<id> <author> <author time> <subject>` per commit, newest committer date first |
| `ls-tree <rev> [<path>]` | `<mode> <type> <id>\t<name>` per entry |
| `cat-file <rev>` | `<type> <size>\n` then the verified payload |
| `diff <rev1> <rev2>` | `:<mode1> <mode2> <id1> <id2> <A\|D\|M\|T>\t<path>` per changed path |
| `rev-parse <rev>` | the 40-digit id |
| `count-objects` | `loose:`, `in-pack:` and `packs:` lines |

## Library example

```go
package main

import (
	"fmt"
	"log"

	"gitrepo"
)

func main() {
	repo, err := gitrepo.Open("/path/to/project/.git")
	if err != nil {
		log.Fatal(err)
	}

	id, err := repo.ResolveRevision("main~2")
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("main~2 is", id)

	// Walk history, newest first (committer date), at most 10 commits.
	head, _ := repo.ResolveRevision("HEAD")
	err = repo.Walk(head, 10, func(id gitrepo.ID, c *gitrepo.Commit) {
		fmt.Printf("%s %s\n", id, c.Subject)
	})
	if err != nil {
		log.Fatal(err)
	}

	// Read and verify an object.
	typ, data, err := repo.VerifyObject(id)
	fmt.Println(typ, len(data), err)

	// Or run a query line exactly as the CLI does.
	out, err := repo.Execute("diff HEAD~1 HEAD")
	fmt.Printf("%s %v\n", out, err)
}
```

A `Repository` caches everything it decodes (pack positions, parsed commits and
trees) for its whole lifetime; it is not safe for concurrent use.

## Design notes

* Pack and index files are read whole into memory once; ids are found with a
  fanout-bounded binary search over the raw index bytes.
* Objects reconstructed from a pack are memoised by pack position, so a delta
  chain is decoded once however many objects sit on top of it.
* Loose objects are listed once at open time; reading one costs a set lookup.
* Inflate stops at the final end-of-block symbol, so objects stored back to
  back in a pack need no length bookkeeping. The Adler-32 trailer is ignored;
  corruption is caught by header checks and, for `cat-file`, the SHA-1 check.
