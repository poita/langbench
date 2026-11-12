# gitrepo

A small Go library and command-line tool that read a git repository straight
off disk and answer queries about it. It does not run `git` and uses no git,
zlib or SHA-1 library: SHA-1, DEFLATE/zlib decoding, loose objects, pack
indexes, packfiles with `OFS_DELTA`/`REF_DELTA` chains, refs and git's revision
syntax are all implemented here, using only the Go standard library.

## Layout

| package            | responsibility                                                   |
|--------------------|------------------------------------------------------------------|
| `gitrepo/sha1`     | SHA-1 (FIPS 180-4)                                               |
| `gitrepo/inflate`  | DEFLATE (RFC 1951) and zlib (RFC 1950) decoder                   |
| `gitrepo/object`   | object types and ids; commit, tree and tag parsing               |
| `gitrepo/odb`      | object database: loose objects, pack index v2, packs, deltas     |
| `gitrepo`          | refs, revision syntax (`^`, `~`, `^{type}`, abbreviations), `Log`, `LsTree`, `CatFile`, `Diff`, `QuotePath` |
| `gitrepo/query`    | the textual command language used by the CLI                     |
| `cmd/gitrepo`      | the command-line tool                                            |

## Build and test

Requires Go 1.27.1.

```
./build.sh          # builds bin/gitrepo (go build ./cmd/gitrepo)
go test ./...       # unit tests; also replays problems/gitrepo/tests when present
```

## Command-line usage

```
./run.sh <input path> <output dir>
```

`<input path>` is a directory containing `repo/` (a `.git` directory or bare
repository) and `commands.txt`, one query per line. For line *k* the tool
writes `<output dir>/NNN.out` (*k* zero-padded to at least three digits). A
query that fails produces the file content `error`; the exit status is 0.
Arguments are separated by single spaces; empty arguments are errors.

| command                  | output                                                        |
|--------------------------|---------------------------------------------------------------|
| `log <rev> [<n>]`        | `<id> <author name> <author time> <subject>`, newest committer date first |
| `ls-tree <rev> [<path>]` | `<mode> <type> <id>TAB<quoted name>` per entry                |
| `cat-file <rev>`         | `<type> <size>`, then the payload; the SHA-1 is verified      |
| `diff <rev1> <rev2>`     | `:<mode1> <mode2> <id1> <id2> <A|D|M|T>TAB<path>`, sorted by path |
| `rev-parse <rev>`        | the object id                                                 |
| `count-objects`          | `loose:`, `in-pack:` and `packs:` counts                      |

Example `commands.txt`:

```
count-objects
rev-parse main~2
log main 5
ls-tree HEAD src
diff v1.0 main
cat-file v1.0^{tree}
```

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

	id, err := repo.RevParse("main~2") // ids, refs, abbreviations, ^ ~ ^{type}
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(id)

	commits, err := repo.Log("HEAD", 5)
	if err != nil {
		log.Fatal(err)
	}
	for _, c := range commits {
		fmt.Printf("%s %s\n", c.ID, c.Subject)
	}

	changes, err := repo.Diff("v1.0", "main")
	if err != nil {
		log.Fatal(err)
	}
	for _, d := range changes {
		fmt.Printf("%c %s\n", d.Status, gitrepo.QuotePath(d.Path))
	}
}
```

A `Repo` reads the pack indexes and the set of loose objects once when opened
and caches every object, commit and tree it decodes, so each is decoded at
most once. It is not safe for concurrent use. Names, paths and messages are
opaque bytes and are never reinterpreted as text.

## Notes

* Only `HEAD`, `refs/**`, `packed-refs` and `objects/` are read; `config`,
  `logs/`, commit-graphs and multi-pack indexes are ignored.
* Packs with an unusable index or header are ignored, as are `.idx`/`.pack`
  files without a partner.
* The zlib Adler-32 trailer is verified, so damaged streams are errors.
