# mdiff

A small C++17 library and command-line tool for line-oriented **diff** and
**patch**. The diff is exact: it always produces a *shortest* edit script
(cost = `N + M - 2·LCS`), using Myers' O(ND) algorithm in its linear-space
"middle snake" form (E. Myers, *An O(ND) Difference Algorithm and Its
Variations*, 1986, §4b). No heuristics, cutoffs or anchoring are used.

- Time O((N+M)·D), extra space O(N+M), recursion depth O(log D).
- Lines are interned to integer ids, so comparisons in the search are O(1).
- Common prefixes and suffixes are trimmed at every level of the recursion.
- Patch applies a script in one pass, O(input size).
- Standard library only (GoogleTest for the tests).

## Layout

| Path | Contents |
| --- | --- |
| `include/mdiff/lines.hpp` | `Line`/`Lines`, `split_lines`, `Interner` |
| `include/mdiff/script.hpp` | `Edit`, `EditScript`, `render_script`, `parse_script_line` |
| `include/mdiff/myers.hpp` | `myers_diff` on integer id sequences |
| `include/mdiff/diff.hpp` | `diff_lines` on text lines |
| `include/mdiff/patch.hpp` | `apply_script` |
| `include/mdiff/protocol.hpp` | `process_request`: the CLI's text format |
| `cli/main.cpp` | thin stdin/stdout wrapper |
| `tests/` | GoogleTest unit tests (with an LCS oracle) |

## Build

Requires a C++17 compiler and CMake ≥ 3.20; GoogleTest for the tests.

```sh
./build.sh                  # Release build into ./build
ctest --test-dir build      # run the unit tests
```

or manually: `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build`.
Use `-DMDIFF_BUILD_TESTS=OFF` to skip the tests (and the GoogleTest dependency).

## Command-line use

`./run.sh` (or `build/mdiff`) reads one request on stdin and writes the
response on stdout. Every line, including the last, ends with `\n`.

```
diff            patch
N               N
<A line 1>      <A line 1>
...             ...
M               K
<B line 1>      <script line 1>
...             ...
```

The mode is the first line. Lines are read by the declared counts and kept
byte-for-byte (whitespace is significant). The response is a count line
followed by that many lines:

- `diff`: an edit script. Each line is a tag (`' '` keep, `'-'` delete,
  `'+'` insert) immediately followed by the line text.
- `patch`: the lines of the patched file B.

```console
$ printf 'diff\n3\na\nb\nc\n3\na\nc\nd\n' | ./run.sh
4
 a
-b
 c
+d
```

Malformed input prints a message to stderr and exits with status 1.

## Library use

```cpp
#include <iostream>
#include "mdiff/diff.hpp"
#include "mdiff/patch.hpp"

int main() {
  mdiff::Lines a = {"a", "b", "c"};
  mdiff::Lines b = {"a", "c", "d"};

  // Shortest edit script: Keep/Delete index into a, Insert indexes into b.
  mdiff::EditScript script = mdiff::diff_lines(a, b);
  std::cout << "cost " << mdiff::script_cost(script) << "\n";   // cost 2

  // Textual form (tag + text per line) ...
  std::string text = mdiff::render_script(script, a, b);
  std::cout << text;

  // ... and applying it again.
  mdiff::Lines b2 = mdiff::apply_script(a, mdiff::split_lines(text));
  // b2 == b
}
```

For callers that already have integer ids, `mdiff::myers_diff(a_ids, b_ids)`
runs the search directly. `mdiff::Lines` holds `std::string_view`s, so the
underlying text must outlive them.

## Tests

`tests/` uses GoogleTest: exhaustive checks over all binary sequences up to
length 6, randomised comparison of the script cost against an O(NM) LCS
oracle, round trips through `diff` and `patch`, and protocol/edge cases
(whitespace, lines that look like tags or counts, lenient input).
