# myersdiff

Exact line-oriented `diff` and `patch` in pure Python (standard library only).

`diff` computes a **shortest** edit script between two files using Myers'
O(ND) algorithm in its linear-space "middle snake" form (Myers 1986, §4b):
lines are interned to integers, common prefixes/suffixes are trimmed, and the
problem is split recursively at the middle snake. Time is O((N+M)·D), space
O(N+M), recursion depth O(log D). There are no heuristics or cost cutoffs, so
the result is always minimal. `patch` applies an edit script in one pass.

## Build and test

```
./build.sh                  # byte-compiles the sources (optional)
python3 -m pytest           # tests (needs pytest; src/ is on the path via pyproject)
```

The project uses a standard `pyproject.toml` / `src` layout; `pip install .`
works, but isn't needed: `run.sh` runs the package with `PYTHONPATH=src`.

## Command line

`./run.sh` reads a request on stdin and writes the reply on stdout.

```
diff                      patch
N                         N
<N lines of A>            <N lines of A>
M                         K
<M lines of B>            <K script lines>
```

The first line is the mode. Script lines are a tag (`' '` keep, `'-'` delete,
`'+'` insert) followed by the line text. Counts are read literally, so content
that looks like a count or a tag is fine; whitespace is preserved exactly.

`diff` prints the script (`K` then `K` script lines); `patch` prints `M` then
the `M` lines of the result. Malformed input exits nonzero with a message on
stderr.

```
$ printf 'diff\n3\na\nb\nc\n3\na\nB\nc\n' | ./run.sh
4
 a
-b
+B
 c
```

## Library

```python
from myersdiff import diff, patch, cost, format_script

a = ["a", "b", "c", "d", "e"]
b = ["a", "B", "c", "c2", "e"]

script = diff(a, b)            # list[Edit(tag, text)], minimal
print(cost(script))            # 4 (deletions + insertions)
print(format_script(script))   # "count\n" + tagged lines
assert patch(a, script) == b
```

Modules: `myers` (algorithm), `script` (`Edit`, formatting/parsing), `patch`
(applying scripts, `PatchError`), `protocol` (stdin/stdout format), `cli`.
