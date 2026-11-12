# gitrepo

A small, dependency-free Python library and command-line tool that reads a git
repository straight off disk and answers queries about it. The object database
is parsed by hand: loose objects, pack indexes (v2), packfiles with
`OFS_DELTA`/`REF_DELTA` chains, refs and `packed-refs`, and git's revision
syntax. DEFLATE/zlib and SHA-1 are implemented in this package. It never runs
`git` and does not use `zlib` or `hashlib`; only the standard library is
required (Python 3.14+).

## Build

There is nothing to install; the project is pure Python.

```sh
./build.sh          # byte-compiles src/ with the standard settings
pip install -e '.[test]'   # optional: editable install with pytest
```

## Command-line usage

```sh
./run.sh <input path> <output dir>
# or: PYTHONPATH=src python3 -m gitrepo <input path> <output dir>
```

`<input path>` is a directory containing `repo/` (a `.git` directory or a bare
repository) and `commands.txt`, one query per line. For line *k* the tool
writes `<output dir>/NNN.out` (`001.out`, `002.out`, ...). A failing query
writes `error` and the exit status is still 0. Tokens are split on single
spaces; empty tokens (double or trailing spaces) make a command fail.

| command | output |
|---|---|
| `rev-parse <rev>` | the object id `<rev>` resolves to |
| `log <rev> [<n>]` | `id author-name author-time subject`, newest committer date first |
| `ls-tree <rev> [<path>]` | `mode type id<TAB>name` with git's C-style quoting |
| `cat-file <rev>` | `type size` line, then the payload; the SHA-1 is verified |
| `diff <rev1> <rev2>` | raw `:mode mode id id status<TAB>path` lines, no rename detection |
| `count-objects` | `loose:`, `in-pack:` and `packs:` counts |

Revisions support `HEAD`, branch/tag names (git's six lookup patterns),
abbreviated ids (4+ hex digits), `^`, `~n`, `^n` and `^{commit|tree|blob|tag|object|}`.
The exact rules are in the problem's `SPEC.md`.

## Library usage

```python
from gitrepo import Repository, run_command, walk, diff_trees

repo = Repository("project/.git")

head = repo.rev_parse(b"HEAD")                 # 40-digit hex str
commit = repo.commit(head)                     # parsed Commit
print(commit.author_name, commit.subject)

for oid, c in walk(repo, head, limit=5):       # git's default log order
    print(oid, c.subject.decode(errors="replace"))

old, new = repo.rev_parse(b"v1^{tree}"), repo.rev_parse(b"HEAD^{tree}")
for change in diff_trees(repo, old, new):
    print(change.status, change.path)

kind, payload = repo.odb.read_verified(head)   # raises if the hash does not match
print(run_command(repo, b"ls-tree HEAD src").decode())
```

Revisions, names and paths are `bytes` (git data is not guaranteed to be
UTF-8); object ids are lowercase hex `str`. All failures derive from
`gitrepo.GitRepoError`.

## Layout

```
src/gitrepo/
  sha1.py        SHA-1 (FIPS 180-4)
  inflate.py     DEFLATE + zlib decoder
  delta.py       pack delta application
  packfile.py    pack index v2 and packfile decoding
  odb.py         object database: loose + packed, caching, abbreviation
  objects.py     tree / commit / tag parsing
  refs.py        loose refs, packed-refs, symbolic refs
  repository.py  Repository: revision syntax and peeling
  history.py     log walk (priority queue)
  diff.py        tree flattening and comparison
  quoting.py     C-style path quoting
  commands.py    the six queries
  cli.py         input/output contract
tests/           pytest suite
```

Every object is decoded and parsed at most once per run; the pack indexes and
loose-object listing are read once at start-up.

## Tests

```sh
python3 -m pytest
```

The tests use `zlib` and `hashlib` only to build fixtures and cross-check the
from-scratch implementations.
