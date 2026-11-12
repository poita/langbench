# diff

A small Clojure library (and command-line tool) for **shortest edit scripts**
between two files of lines, and for applying such scripts. It implements
Myers' O(ND) difference algorithm in its linear-space, divide-and-conquer
("middle snake") form, with common prefix/suffix trimming and line interning.
The result is always *minimal* — no cost cutoffs or heuristics — and uses
O(N+M) memory with O(log D) recursion depth. Only the Clojure standard library
is used.

Reference: E. Myers, "An O(ND) Difference Algorithm and Its Variations", 1986.

## Layout

| Namespace      | Responsibility                                                    |
|----------------|-------------------------------------------------------------------|
| `diff.core`    | Public API: `diff`, `patch`, `cost`, `format-script`, `parse-script` |
| `diff.myers`   | Linear-space Myers search over integer id arrays (`edit-masks`)   |
| `diff.intern`  | Interning lines to integer ids for O(1) comparison                |
| `diff.script`  | Building, applying, rendering and parsing edit scripts            |
| `diff.io`      | Request parsing / response rendering for the CLI                  |
| `diff.main`    | The command-line entry point                                      |

## Build

Requires Java and the `clojure` CLI (tested with Clojure 1.12.6, Java 27).

```sh
./build.sh      # resolves deps and AOT-compiles the CLI into classes/
```

## Tests

```sh
clojure -M:test
```

Uses the Cognitect test-runner; the properties (via `test.check`) compare the
script cost against a reference dynamic-programming LCS.

## Command-line use

`./run.sh` reads a request on stdin and writes the response to stdout. Every
line is `\n`-terminated; the first line is the mode.

```
diff            patch
N               N
<N lines of A>  <N lines of A>
M               K
<M lines of B>  <K script lines>
```

`diff` prints `K` followed by a minimal edit script of `K` lines; `patch`
prints the line count of the result followed by the lines. Counts, not
content, delimit blocks, so lines may look like counts or tags. Script lines
are a tag followed by the line text: `" "` keep, `-` delete, `+` insert.
Whitespace is significant. On malformed input the tool prints an error to
stderr and exits 1.

```sh
printf 'diff\n3\na\nb\nc\n3\na\nc\nd\n' | ./run.sh
# 4
#  a
# -b
#  c
# +d
```

## Library use

```clojure
(require '[diff.core :as diff])

(def a ["a" "b" "c"])
(def b ["a" "c" "d"])

(def script (diff/diff a b))
;=> [[:keep "a"] [:delete "b"] [:keep "c"] [:insert "d"]]

(diff/cost script)          ;=> 2
(diff/format-script script) ;=> [" a" "-b" " c" "+d"]
(diff/patch a script)       ;=> ["a" "c" "d"]
```

Lines may be any values with value equality. `diff/patch` accepts any valid
script, minimal or not, and throws `ex-info` if the script does not match the
original lines.
