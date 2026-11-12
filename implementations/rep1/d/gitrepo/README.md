# gitrepo

`gitrepo` reads a git repository straight off disk and answers queries about
it — `log`, `ls-tree`, `cat-file`, `diff`, `rev-parse`, `count-objects` —
without running `git` and without any git, zlib or SHA-1 library. The object
database, DEFLATE decompression and SHA-1 are implemented here, in D, using
only Phobos.

It is split into a reusable library (`source/gitrepo/`) and a thin
command-line tool (`app/main.d`).

## Building

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0).

```sh
./build.sh                                # runs: dub build -b release --compiler=ldc2
dub test --compiler=ldc2                  # unit and integration tests
```

The executable is written to `./gitrepo`.

## Command-line use

```
gitrepo <input path> <output dir>      # or: ./run.sh <input path> <output dir>
```

`<input path>` is a directory holding

* `repo/` — the contents of a `.git` directory (or a bare repository), and
* `commands.txt` — one query per line, tokens separated by single spaces.

For the command on line *k* the tool writes `<output dir>/NNN.out` (*k*
zero-padded to at least three digits). A command that fails — unknown
command, bad arguments, unresolvable revision, missing or damaged object —
produces a file containing `error`. The exit status is 0 whenever the batch ran.

| command | output |
|---|---|
| `log <rev> [<n>]` | `<id> <author> <author-time> <subject>` per commit, newest committer date first |
| `ls-tree <rev> [<path>]` | `<mode> <type> <id>\t<name>` per tree entry |
| `cat-file <rev>` | `<type> <size>\n` + payload, after verifying the object's SHA-1 |
| `diff <rev1> <rev2>` | raw recursive tree diff (`:<mode1> <mode2> <id1> <id2> <A/D/M/T>\t<path>`) |
| `rev-parse <rev>` | the object id |
| `count-objects` | `loose:`, `in-pack:` and `packs:` counts |

Revisions understand `HEAD`, branch/tag names (with git's `refs/…` search
order), abbreviated ids, `^`, `^n`, `~n` and `^{commit|tree|blob|tag|object|}`.
Names, paths and messages are handled as raw bytes, never decoded as UTF-8.

## Library layout

| module | responsibility |
|---|---|
| `gitrepo.sha1` | SHA-1 (FIPS 180-4) |
| `gitrepo.inflate` | zlib / DEFLATE decoder |
| `gitrepo.delta` | git delta application |
| `gitrepo.packindex` | pack index v2 lookup (fanout + binary search) |
| `gitrepo.store` | loose + packed object store with `OFS_DELTA`/`REF_DELTA`; per-run caching |
| `gitrepo.parse` | commit, tree and tag parsers |
| `gitrepo.refs` | `HEAD`, loose refs, `packed-refs` |
| `gitrepo.revision` | revision resolution and peeling |
| `gitrepo.repository` | `Repository`: store + refs + parsed-object caches |
| `gitrepo.commands` | the six queries |
| `gitrepo.quote` | git path quoting |
| `gitrepo.batch` | the `commands.txt` → `NNN.out` driver |

Every failure in the library is reported by throwing `gitrepo.errors.GitError`.

Notes on behaviour: the Adler-32 trailer of zlib streams is not checked
(corruption is caught by the DEFLATE decoder, the object header check, and by
`cat-file`'s SHA-1 verification). Objects are inflated and parsed at most once
per `Repository`; `log` uses a priority queue; abbreviated ids are resolved
by binary search.

## Library example

```d
import std.stdio;
import gitrepo.repository;
import gitrepo.revision;
import gitrepo.objecttype;
import gitrepo.errors;

void main()
{
    auto repo = new Repository("/path/to/project/.git");
    try
    {
        // Resolve a revision and walk to its commit and tree.
        auto id = resolveRevision(repo, "main~2");
        auto commit = repo.commit(peel(repo, id, ObjectType.commit));
        writeln("subject: ", cast(const(char)[]) commit.subject);
        foreach (entry; repo.tree(commit.tree))
            writefln("%06o %s %s\t%s", entry.mode, entry.typeName, entry.id, cast(const(char)[]) entry.name);
    }
    catch (GitError e)
    {
        writeln("failed: ", e.msg);
    }
}
```

The `gitrepo.commands.execute(repo, "log main 5")` function runs a command line
exactly as the CLI does and returns the output bytes.

To use the library from another dub project, depend on the `library`
configuration:

```json
"dependencies": { "gitrepo": { "path": "../gitrepo" } },
"subConfigurations": { "gitrepo": "library" }
```

## Layout

```
app/main.d          command-line entry point
source/gitrepo/     the library
tests/              integration tests and fixture builders (used by `dub test`)
build.sh run.sh     build and run helpers
```

## Licence

MIT.
