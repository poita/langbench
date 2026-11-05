# datalog

A Datalog engine with stratified negation, written in D using only the standard
library. It parses a program of facts, rules and queries, rejects unsafe or
non-stratifiable programs, computes the perfect model by semi-naive bottom-up
evaluation, and answers the queries.

The library (`source/datalog/`) is split by responsibility; the command-line
tool (`app/main.d`) is a thin wrapper around it.

| module            | role                                                                    |
|-------------------|-------------------------------------------------------------------------|
| `datalog.lexer`   | tokeniser, `ParseException`                                             |
| `datalog.ast`     | `Program`, `Rule`, `Atom`, …; interning and ordering of constants       |
| `datalog.parser`  | `parseProgram`                                                          |
| `datalog.analysis`| rule safety (`isSafe`) and stratification (`stratify`, Tarjan SCC)     |
| `datalog.relation`| append-only tuple relations with a hash set and incremental hash indexes|
| `datalog.plan`    | compiles rules to join plans (index lookups, probes, filters)           |
| `datalog.engine`  | semi-naive evaluation, `evaluate`                                       |
| `datalog.query`   | `answerQuery`, output formatting                                        |
| `datalog`         | `package.d`: re-exports everything and provides `solve`                 |

Constants are interned to integers and renumbered so that id order equals the
language's order (integers numerically, then identifiers bytewise); evaluation
and sorting then work on plain integers.

## Build

Requires LDC and dub.

```
./build.sh                                  # or: dub build -b release --compiler=ldc2
dub test --compiler=ldc2                    # unit tests (tests/)
```

This produces `bin/datalog`.

## Command line

`run.sh` (or `bin/datalog`) reads a whole program on stdin and writes the
answers to stdout:

```
$ cat tc.dl
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
$ ./run.sh < tc.dl
path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
```

For every query the matching tuples are printed in ascending order followed by
`-- N`. If a rule is unsafe (a head, negated-atom or comparison variable does not
occur in a positive body atom) or the program is not stratifiable, the only
output is `error`. Both cases exit with status 0. Syntactically malformed input
prints a message on stderr and exits with status 1.

Syntax: `p(a, 1, X, _).` facts and atoms; `h(X) :- p(X), not q(X), X < 5.` rules
with `not` and the comparisons `< <= > >= = !=`; `?- p(X, a).` queries; `%`
comments. Constants are integers or lowercase identifiers; ordering puts every
integer before every identifier.

## Library example

```d
import datalog;

void main()
{
    auto result = solve(
        "edge(1,2). edge(2,3). edge(3,4).\n"
      ~ "path(X,Y) :- edge(X,Y).\n"
      ~ "path(X,Z) :- edge(X,Y), path(Y,Z).\n"
      ~ "?- path(1, X).");
    assert(result.ok);
    assert(result.output == "path(1, 2)\npath(1, 3)\npath(1, 4)\n-- 3\n");
}
```

`solve` throws `ParseException` for malformed text. The stages are also usable
separately:

```d
auto program = parseProgram(source);
Stratification strat;
if (isSafe(program) && stratify(program, strat))
{
    auto db = evaluate(program, strat);          // db.relations[predicateId]
    // answerQuery(program, db, program.queries[0], texts, outputAppender);
}
```

To depend on the package from another dub project use
`dependency "datalog" path="..."` with `subConfiguration "datalog" "library"`.

## Layout

```
dub.sdl  build.sh  run.sh
source/datalog/   library
app/main.d        command-line tool
tests/            unit tests (run by `dub test`)
```
