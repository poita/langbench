# regex

A small backtracking regular-expression engine in C++17 with Perl-style
semantics (leftmost match, greedy quantifiers, ordered alternation), plus a
batch command-line tool. It reports the first match in a subject together
with the span of every capture group.

Supported syntax: literals, `.`, classes (`[a-z_]`, `[^...]`, ranges, `\d \w \s`
and their complements inside classes), escapes (`\d \D \w \W \s \S`, `\.` etc.),
anchors `^` `$`, capturing groups `( )`, alternation `|`, and greedy
quantifiers `* + ? {n} {n,} {n,m}`. No lazy quantifiers, backreferences or
lookaround. The authoritative definition is `problems/regex/SPEC.md`.

## Design

| Module | Files | Responsibility |
| --- | --- | --- |
| character sets | `charset.hpp/.cpp` | 256-bit byte sets |
| syntax tree | `ast.hpp` | node types |
| parser | `parser.hpp/.cpp` | recursive descent, pattern → tree, `ParseError` |
| analysis | `analysis.hpp/.cpp` | possible first characters, "anchored at 0" |
| compiler | `program.hpp`, `compiler.cpp` | tree → instructions (counted quantifiers expanded) |
| matcher | `matcher.hpp/.cpp` | backtracking VM with an explicit stack (no recursion) |
| public API | `regex.hpp/.cpp` | `regex::Regex` |
| CLI | `cli/` | batch protocol (`batch.cpp`) and `main.cpp` |

Capture and loop-bookkeeping writes are recorded on the backtrack stack, so
undoing a failed path costs time proportional to the writes it made. Start
positions are tried in order; positions whose character cannot begin a match
are skipped and patterns that must begin with `^` are tried only at offset 0.
Backtracking is exponential in the worst case, as with any such engine.

## Build

Requires CMake ≥ 3.20 and a C++17 compiler; GoogleTest is needed only for tests.

```sh
./build.sh            # Release build into ./build
./build/bin/regex     # the CLI (or ./run.sh)
cd build && ctest     # run the unit tests
```

CMake options: `REGEX_BUILD_CLI` (ON), `REGEX_BUILD_TESTS` (ON; skipped with a
warning if GoogleTest is not found).

## Command-line use

`regex` reads a batch on stdin and writes one line per subject on stdout:

```
N
pattern_1
M_1
subject_1_1
...
```

Lines are taken verbatim (empty lines and leading/trailing spaces are
significant). For each subject the output is `no`, or
`match <start> <end>` followed by `|<begin>,<end>` (or `|-` if unset) for each
group in order.

```console
$ printf '1\n(a|(b))+\n2\nba\nab\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
```

On malformed input or an invalid pattern it prints a message to stderr and
exits with status 1.

## Library use

```cpp
#include <iostream>
#include "regex/regex.hpp"

int main() {
  regex::Regex re("(\\w+)@(\\w+)\\.com");        // throws regex::ParseError if invalid
  if (auto m = re.search("mail bob@example.com now")) {
    std::cout << m->span.begin << ".." << m->span.end << "\n";   // 5..20
    for (const auto& g : m->groups)                              // groups[0] is group 1
      if (g) std::cout << g->begin << "," << g->end << "\n";     // 5,8 then 9,16
  }
}
```

`Regex` is immutable and thread-safe. When matching many subjects with one
pattern, construct a `regex::Matcher m(re.program())` once and call
`m.search(subject, match)` to reuse its scratch memory (a `Matcher` itself is
not thread-safe). Link against the `regex::engine` target.

## Tests

`tests/` holds GoogleTest suites for each module, the examples from the
specification, and a differential test comparing the VM with a direct recursive
transcription of the matching definition on randomly generated patterns.
