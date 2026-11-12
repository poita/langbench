# rx — a backtracking regular-expression engine

`rx` is a small C++17 library that implements Perl-style regular expressions
(leftmost match, greedy quantifiers, ordered alternation) for a deliberately
small syntax and reports the first match together with the position of every
capture group. It is written from scratch with the standard library only, and
comes with `regex_cli`, a batch tool that runs many patterns over many subject
lines.

## Layout

| Path | Responsibility |
|------|----------------|
| `include/rx/charset.hpp` | 256-bit character set |
| `include/rx/ast.hpp`, `parser.hpp` | syntax tree and recursive-descent parser |
| `include/rx/program.hpp`, `src/compiler.cpp` | compiles the tree into a flat instruction list; computes the first-character set and start-anchoring |
| `include/rx/matcher.hpp` | backtracking VM with an explicit heap stack (no recursion, so `.*` over long subjects is safe) |
| `include/rx/regex.hpp` | `rx::Regex`, the convenient entry point |
| `include/rx/batch.hpp` | the line-oriented batch protocol used by the CLI |
| `cli/main.cpp` | thin `regex_cli` wrapper around `rx::run_batch` |
| `tests/` | GoogleTest unit tests plus a differential test against a direct transcription of the matching definition |

## Pattern syntax

```
regex      := branch ( '|' branch )*
branch     := piece*
piece      := atom quantifier?
atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
quantifier := '*' | '+' | '?' | '{n}' | '{n,}' | '{n,m}'
```

* `.` any character; `^` / `$` match only at the start / end of the subject.
* Escapes: `\d \w \s` and complements `\D \W \S`; `\` plus any
  non-alphanumeric character is that character literally.
* Classes: `[abc]`, `[^a-z]`, `[\d_-]`; `-` is literal first, last, or escaped.
* Every `( )` group captures, numbered by the position of its `(`.
* Quantifiers are greedy; counts are limited to 1000 (and a pattern may expand
  to at most 2,000,000 instructions). An iteration beyond the minimum that
  matches the empty string ends the repetition.
* Invalid patterns throw `rx::ParseError`.

Matching semantics follow the continuation-passing definition in the problem
specification exactly: ordered choice, greedy repeats, captures keep the value
from the last completed iteration on the successful path, and writes made on
abandoned paths are undone (via an undo log, so the cost is proportional to the
writes).
Search tries start positions 0..len in order, skipping positions that cannot
begin a match (computed once per pattern from the first-character set; patterns
that must begin with `^` are tried at 0 only).

## Build

Requires a C++17 compiler and CMake ≥ 3.20 (GoogleTest for the tests).

```sh
./build.sh                 # Release build into ./build
(cd build && ctest)        # run the unit tests
```

Options: `-DRX_BUILD_CLI=OFF`, `-DRX_BUILD_TESTS=OFF`.

## Command-line tool

`./run.sh` (i.e. `build/regex_cli`) reads a batch on stdin:

```
N
pattern_1
M_1
subject_1_1
...
```

and prints one line per subject: `no`, or `match <start> <end>` followed by
`|<gs>,<ge>` (or `|-` if unset) for each group in order.

```console
$ printf '2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
match 1 6
no
```

Lines are positional and taken verbatim (empty lines, leading/trailing spaces
and integer-looking lines are all legitimate). Malformed input or an invalid
pattern prints a message on stderr and exits with status 1.

## Library example

```cpp
#include <iostream>
#include "rx/regex.hpp"

int main() {
  rx::Regex re("(a|ab)(c|bcd)(d*)");          // throws rx::ParseError if invalid
  if (auto m = re.search("abcd")) {
    std::cout << m->begin << ".." << m->end << '\n';       // 0..4
    for (std::size_t g = 1; g <= re.group_count(); ++g) {
      const rx::Span& s = m->group(g);
      if (s.matched()) std::cout << g << ": " << s.begin << ',' << s.end << '\n';
    }
  }

  // For many subjects, reuse a Matcher (it keeps its scratch memory).
  rx::Matcher matcher(re.program());
  rx::Match out;
  bool found = matcher.search("xabcd", out);
}
```

Link against the `rx` target (`target_link_libraries(app PRIVATE rx::rx)`).
