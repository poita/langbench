# mdiff

Exact line-oriented **diff** and **patch** in D, using only the standard
library. `diff` prints a *shortest* edit script between two files (Myers' O(ND)
algorithm in its linear-space "middle snake" form, with line interning and
common prefix/suffix trimming); `patch` applies such a script.

* Time O((N+M)·D), space O(N+M), where D is the size of the minimal script.
* Always exact: no heuristics, cut-offs or anchoring on unique lines.
* Lines are compared byte for byte; whitespace and non-ASCII text are
  significant. Line text is never copied: lines are views into the input buffer.

## Layout

| Path | Contents |
|------|----------|
| `source/mdiff/` | the library (`import mdiff;`) |
| `app/main.d` | the thin command-line front end |
| `tests/` | unit tests (separate from the library sources) |
| `dub.sdl` | package manifest (`cli`, `library`, `unittest` configurations) |
| `build.sh`, `run.sh` | build / run wrappers |

Library modules: `mdiff.diff` (`diffLines`), `mdiff.patch` (`applyScript`),
`mdiff.myers` (the algorithm on integer ids), `mdiff.intern` (line interning),
`mdiff.edit` (`Edit`, `EditKind`), `mdiff.script` (text rendering),
`mdiff.lines` (zero-copy line reader), `mdiff.protocol` (the CLI's I/O
contract), `mdiff.errors`.

## Build and test

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0).

```
./build.sh                     # dub build -b release --compiler=ldc2  ->  bin/mdiff
dub test --compiler=ldc2       # unit tests
```

## Command-line use

`mdiff` (or `./run.sh`) reads one request on standard input and writes the
response to standard output. Counts are decimal; every line, including the
last, ends in `\n`. Content is read strictly by the declared counts, so a line
may look like a count, a tag or be empty.

```
diff                        patch
N                           N
<N lines of A>              <N lines of A>
M                           K
<M lines of B>              <K script lines>
```

Output is a count line followed by that many lines: for `diff` the edit
script, for `patch` the resulting file. A script line is one tag character
followed by the line text: ` ` keep, `-` delete, `+` insert (`+` alone inserts
an empty line). The script produced by `diff` is valid and minimal.

```
$ printf 'diff\n3\na\nb\nc\n3\na\nB\nc\n' | ./run.sh
4
 a
-b
+B
 c
```

Leniencies on input: `\r\n` line endings, a missing final newline, trailing
spaces/tabs on count lines and extra empty lines at the end are accepted.
Malformed input gives a message on stderr and exit status 1.

## Library use

```d
import std.array : appender;
import std.stdio : write;
import mdiff;

void main()
{
    const(char)[][] a = ["one", "two", "three"];
    const(char)[][] b = ["one", "2", "three", "four"];

    // Minimal edit script: Edit(kind, index) with kind keep/remove/insert.
    Edit[] edits = diffLines(a, b);
    assert(cost(edits) == 3);

    // Render it in the textual format...
    auto sink = appender!(char[])();
    appendScript(sink, edits, a, b);
    write(sink.data);

    // ...and apply a textual script (lines tagged ' ', '-', '+') back to A.
    const(char)[][] script = [" one", "-two", "+2", " three", "+four"];
    assert(applyScript(a, script) == b);
}
```

For sequences you have already reduced to integers, call
`shortestEdits(const(int)[] a, const(int)[] b)` from `mdiff.myers` directly.
Use `mdiff.protocol.process(input)` to run the whole stdin/stdout protocol on
a string.

## Algorithm notes

1. Lines of both files are interned to dense integer ids, so all comparisons
   in the search are integer comparisons.
2. Each (sub)problem trims its common prefix and suffix; if one side is then
   empty the rest is pure insertion/deletion.
3. Otherwise the middle snake is found by running the greedy furthest-reaching
   search forward and backward in lockstep until the frontiers overlap, and
   the two halves are solved recursively. The two frontier arrays are allocated
   once and reused; recursion depth is O(log D).
