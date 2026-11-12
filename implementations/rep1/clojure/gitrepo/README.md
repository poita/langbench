# gitrepo

A small Clojure library — and a command-line tool on top of it — that reads a
git repository straight off disk and answers queries about it: `log`,
`ls-tree`, `cat-file`, `diff`, `rev-parse` and `count-objects`.

Everything is implemented from scratch on the Clojure/Java standard library:
SHA-1, zlib/DEFLATE inflation, loose objects, pack index v2 and packfiles
(including `OFS_DELTA` / `REF_DELTA` chains), refs and `packed-refs`, and git's
revision syntax (`^`, `~`, `^{type}`, abbreviated ids). It never runs `git`.

The behaviour is specified in `problems/gitrepo/SPEC.md`.

## Requirements

Java 27 and the Clojure CLI (`clojure`) with Clojure 1.12.6. Tests also use
`org.clojure/test.check` and the Cognitect test-runner.

## Build

```sh
./build.sh        # AOT-compiles the CLI into target/classes
```

## Command-line use

```sh
./run.sh <input path> <output dir>
```

`<input path>` is a directory holding `repo/` (a `.git` or bare directory) and
`commands.txt`, one query per line (tokens separated by single spaces). The
answer to line *k* is written to `<output dir>/NNN.out` (`001.out`, `002.out`,
…). A query that fails — unknown command, wrong arguments, unresolvable
revision, missing or damaged object — writes `error`. The exit status is 0.

| command | output |
|---|---|
| `log <rev> [<n>]` | `<id> <author> <author time> <subject>`, newest committer date first |
| `ls-tree <rev> [<path>]` | `<mode> <type> <id>TAB<name>` |
| `cat-file <rev>` | `<type> <size>`, then the verified payload |
| `diff <rev1> <rev2>` | `:<mode1> <mode2> <id1> <id2> <A/D/M/T>TAB<path>` |
| `rev-parse <rev>` | the object id |
| `count-objects` | `loose:`, `in-pack:` and `packs:` counts |

## Library

```clojure
(require '[gitrepo.core :as g])

(def repo (g/open-repo "/path/to/project/.git"))

(g/rev-parse repo "main~2")          ;=> "0f5efe1e004bb7db3eed8d431f1dd464c55070b7"
(map (juxt :id :subject) (g/log repo "HEAD" 3))
(g/ls-tree repo "HEAD" "src")        ;=> [{:mode 33188 :type :blob :id "…" :name "core.clj"} …]
(g/diff repo "v1.0" "HEAD")          ;=> [{:path "README.md" :status :M :mode1 … } …]
(:type (g/cat-file repo "HEAD"))     ; cat-file verifies the SHA-1 of the object
(g/count-objects repo)               ;=> {:loose 5 :in-pack 0 :packs 0}
```

Queries throw an `ex-info` when they fail (`gitrepo.error/failure?` recognises
it). Names, messages and idents are returned as *byte-strings*: ISO-8859-1
strings with one char per repository byte, so non-UTF-8 data survives
untouched; `gitrepo.hex/latin1-bytes` gets the original bytes back.

A repo is a plain map; opening it lists loose objects and loads pack indexes
once, and reading objects fills caches inside it, so reuse one repo for many
queries.

### Modules

| namespace | responsibility |
|---|---|
| `gitrepo.core` | public API: `open-repo`, `rev-parse`, `cat-file`, `log`, `ls-tree`, `diff`, `count-objects` |
| `gitrepo.rev` | revision syntax and peeling |
| `gitrepo.refs` | `HEAD`, loose refs, `packed-refs`, symbolic refs |
| `gitrepo.object` | commit / tree / tag parsing, subjects, idents |
| `gitrepo.store` | loose objects and packs behind one object reader, with caches |
| `gitrepo.pack` | pack index v2 lookup and pack object headers |
| `gitrepo.delta` | delta application |
| `gitrepo.inflate` | zlib / DEFLATE decoder |
| `gitrepo.sha1` | SHA-1 |
| `gitrepo.quote`, `gitrepo.format` | git path quoting and output formatting |
| `gitrepo.command`, `gitrepo.main` | the command language and the CLI |

## Tests

```sh
clojure -M:test
```

The suite has unit tests (SHA-1 against the JDK, inflate against
`java.util.zip.Deflater`, deltas, quoting), property tests with test.check,
end-to-end tests over repositories built on disk (loose, packed, deltas, refs),
and, when `../problems/gitrepo/tests` exists, the shared corpus.
