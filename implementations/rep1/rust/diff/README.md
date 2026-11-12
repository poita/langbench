# linediff

A small Rust library and command-line tool for line-oriented **diff** and
**patch**.

* `diff` produces a *shortest* edit script (keep / delete / insert) between two
  files, using Myers' O(ND) algorithm in its linear-space "middle snake" form.
  It is exact: no cost cut-offs, no heuristics, no anchoring on unique lines.
* `patch` applies an edit script (not necessarily minimal) to a file.

Only the standard library is used. Lines are compared byte for byte, so
whitespace is significant.

Complexity: diff is O((N+M)·D) time and O(N+M) extra space, with recursion
depth O(log D); patch is linear.

## Build

```sh
cargo build --release      # or ./build.sh
cargo test                 # unit, integration and doc tests
```

The binary is `target/release/linediff`; `./run.sh` runs it from any directory.

## Command line

The tool reads one request on stdin and writes the result to stdout. Every
line, including the last, ends in `\n`. The first line is the mode.

```
diff            patch
N               N
<N lines of A>  <N lines of A>
M               K
<M lines of B>  <K script lines>
```

A script line is a one-character tag followed by the line text: `' '` keeps
the next line of A, `-` deletes it, `+` inserts the text. Output:

* `diff`: `K`, then the `K` script lines.
* `patch`: `M`, then the `M` lines of the result.

Example:

```console
$ printf 'diff\n3\na\nb\nc\n3\na\nB\nc\n' | ./run.sh
4
 a
-b
+B
 c
$ printf 'patch\n3\na\nb\nc\n4\n a\n-b\n+B\n c\n' | ./run.sh
3
a
B
c
```

Malformed input gives a message on stderr and a nonzero exit status.

## Library

```rust
use linediff::{cost, diff, patch, Edit, ScriptLine, Tag};

let a = ["a", "b", "c", "a", "b", "b", "a"];
let b = ["c", "b", "a", "b", "a", "c"];

let edits = diff(&a, &b);
assert_eq!(cost(&edits), 5); // the minimum

let script: Vec<ScriptLine<&str>> = edits
    .iter()
    .map(|e| match *e {
        Edit::Keep { a: i, .. } => ScriptLine { tag: Tag::Keep, text: a[i] },
        Edit::Delete { a: i } => ScriptLine { tag: Tag::Delete, text: a[i] },
        Edit::Insert { b: j } => ScriptLine { tag: Tag::Insert, text: b[j] },
    })
    .collect();
assert_eq!(patch(&a, &script).unwrap(), b.to_vec());
```

Modules:

| module | role |
| --- | --- |
| `diff` | `diff(a, b)` for any `Eq + Hash` element type |
| `myers` | the algorithm on `u32` id sequences (`diff_ids`) |
| `intern` | maps distinct lines to integer ids so comparison is O(1) |
| `patch` | `patch(a, script)` |
| `edit` | `Edit`, `Tag`, `ScriptLine`, `cost` |
| `format` | the stdin/stdout text format (`parse_request`, `run`, ...) |
| `error` | `Error` |

Run `cargo doc --open` for the API documentation.
