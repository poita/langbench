# myersdiff

An exact line-oriented diff and patch library for D, plus a small
command-line tool. The diff is a *shortest* edit script, computed with
Myers' O(ND) algorithm in its linear-space "middle snake" form
(E. Myers, *An O(ND) Difference Algorithm and Its Variations*, 1986).

- Lines are interned to integer ids so comparisons are O(1).
- Common prefixes and suffixes are trimmed at every recursion level.
- Time O((N+M)·D), space O(N+M) beyond input/output, recursion depth O(log D).
- No heuristics: no cost cut-offs, no discarding of unique lines, no
  patience/histogram anchoring. The result is always minimal.
- Only the D standard library is used; the diff itself is implemented here.

## Build

Requires LDC and dub.

```sh
dub build -b release --compiler=ldc2    # builds bin/diff
./build.sh                              # same thing, from any directory
dub test --compiler=ldc2                # run the unit tests
```

## Command-line use

`bin/diff` (or `./run.sh`) reads a request on stdin and writes the result on
stdout. The first line is the mode.

```
diff            patch
N               N
<N lines of A>  <N lines of A>
M               K
<M lines of B>  <K script lines>
```

A script is a count line followed by one line per operation: a tag
(`' '` keep, `'-'` delete, `'+'` insert) immediately followed by the line text.

```sh
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

Lines are taken verbatim (whitespace is significant). `patch` prints the
number of lines of the result followed by the lines. Malformed input gives a
message on stderr and exit status 1.

## Library use

Add the package as a dependency (`dependency "myersdiff" path="..."`) and
`import myersdiff;`.

```d
import myersdiff;
import std.array : appender;
import std.stdio : write;

void main()
{
    const(char)[][] a = ["a", "b", "c"];
    const(char)[][] b = ["a", "B", "c"];

    // Shortest edit script as (kind, index) pairs.
    Edit[] edits = diffLines(a, b);
    assert(cost(edits) == 2);

    // Render it in the textual script format...
    auto sink = appender!string;
    writeScript(sink, edits, a, b);
    write(sink.data);               // "4\n a\n-b\n+B\n c\n"

    // ...and apply a script back to A.
    auto script = parseScript([" a", "-b", "+B", " c"]);
    assert(applyScript(a, script) == b);
}
```

### Modules

| module               | contents                                                   |
|----------------------|------------------------------------------------------------|
| `myersdiff.edit`     | `Edit`, `EditKind`, `cost`                                 |
| `myersdiff.intern`   | `Interner`, `internLines` (line → integer id)              |
| `myersdiff.myers`    | `diffIds` (on id sequences), `diffLines` (on text lines)   |
| `myersdiff.script`   | `writeScript`, `parseScript`, `ScriptLine`                 |
| `myersdiff.patch`    | `applyScript`, `PatchException`                            |
| `myersdiff.parse`    | `parseRequest`, `Request`, `ParseException`                |
| `myersdiff.protocol` | `process`: the whole stdin → stdout contract               |

## Tests

The unit tests live next to the code (`unittest` blocks). The diff is checked
against a dynamic-programming LCS on tens of thousands of random inputs
(validity of the script and minimality of its cost).

## Layout

```
dub.sdl          package manifest (configurations: cli, library)
source/myersdiff library
app/main.d       command-line tool
build.sh run.sh  build and run helpers
```
