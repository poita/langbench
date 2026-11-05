# datalog

A small Datalog engine with stratified negation, written in D using only the
standard library. It reads a program (facts, rules and queries), rejects
programs that are unsafe or not stratifiable, computes the perfect model by
semi-naive bottom-up evaluation, and prints the answers to the queries.

The package is a reusable library (`datalog`) plus a thin command-line tool.

## Features

* Facts, recursive rules (including non-linear and mutually recursive ones),
  negation (`not p(X)`), comparisons (`< <= > >= = !=`), anonymous variables (`_`).
* Constants are integers or identifiers, with one total order (integers first,
  then identifiers bytewise) used for comparisons and for sorting output.
* Safety and stratification checks run before any evaluation.
* Evaluation interns constants to order-preserving integer ids, compiles each
  rule into a join plan (hash-indexed nested loops), and runs semi-naive
  rounds per strongly connected component of the predicate graph.

## Building

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0).

```sh
./build.sh                                  # builds ./datalog
# or directly:
dub build -b release --compiler=ldc2
```

Unit tests (they live in `tests/`, separate from the library source):

```sh
dub test --compiler=ldc2
```

## Command-line use

`datalog` reads one program from standard input and writes the answers to
standard output. `run.sh` is a wrapper that works from any directory.

```sh
$ cat > prog.dl <<'END'
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
END
$ ./run.sh < prog.dl
path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
```

For every query, in input order, the matching tuples are printed in ascending
order, one `pred(v1, v2, ...)` per line, followed by `-- N` (the count). If any
rule is unsafe, or the program is not stratifiable, the only output is
`error`. The exit status is 0 in both cases. A syntactically malformed program
(outside the specified input language) makes the tool print a diagnostic on
stderr and exit with status 1.

Language summary:

```
fact    p(a, 1).
rule    q(X, Z) :- p(X, Y), not r(Y), Y < 10, q(Y, Z).
query   ?- q(a, X).
```

Variables start with an upper-case letter, constants with a lower-case letter
or are integers, `_` is a fresh anonymous variable, `%` starts a comment.

## Library use

Add the package as a dependency (`"datalog": {"path": "../datalog"}` with
`"subConfigurations": {"datalog": "library"}`) and import `datalog`.

One call, same behaviour as the CLI:

```d
import datalog;

void main()
{
    auto output = runProgram(`
        edge(1, 2). edge(2, 3).
        path(X, Y) :- edge(X, Y).
        path(X, Z) :- edge(X, Y), path(Y, Z).
        ?- path(1, X).`);
    assert(output == "path(1, 2)\npath(1, 3)\n-- 2\n");
}
```

Step by step:

```d
import datalog;
import std.stdio;

void main()
{
    auto program = parseProgram("p(1). p(2). q(X) :- p(X), X > 1. ?- q(X).");
    auto model = evaluate(program);   // throws UnsafeRuleException / StratificationException
    foreach (row; answer(model, program.queries[0]))
        writeln(program.constantText(row[0]));   // prints 2
}
```

### Modules

| module             | responsibility                                                        |
|--------------------|-----------------------------------------------------------------------|
| `datalog.lexer`    | tokeniser                                                             |
| `datalog.ast`      | `Program`, `Rule`, `Atom`, `Term`; constant interning and ordering    |
| `datalog.parser`   | `parseProgram` (one pass, interning as it goes, then canonical ids)   |
| `datalog.analysis` | `checkSafety`, `stratify` (Tarjan SCC over the predicate graph)       |
| `datalog.relation` | `Relation` (append-only tuples + hash set), `Index` (incremental hash index) |
| `datalog.plan`     | `compilePlan`: rule to join plan (scan / index lookup / membership probe) |
| `datalog.eval`     | `evaluate`, `Model`: semi-naive fixpoint per component                |
| `datalog.query`    | `answer`, `renderAnswer`                                              |
| `datalog.errors`   | `ParseException`, `UnsafeRuleException`, `StratificationException`    |

## Layout

```
dub.json        package manifest (configurations: cli, library, unittest)
source/datalog/ the library
app/main.d      the command-line tool
tests/          unit tests (module names tests.*)
build.sh run.sh build and run helpers
```
