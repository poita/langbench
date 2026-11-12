# datalog

A small Datalog engine with stratified negation, written in D using only the
standard library. It reads a program (facts, rules and queries), checks that it
is *safe* and *stratifiable*, computes its perfect model with **semi-naive
bottom-up evaluation** and prints the answers to the queries.

* constants are integers or identifiers; all integers sort before all identifiers;
* rules may be recursive (also non-linearly and mutually) and may use negated
  atoms (`not p(X)`) and the comparisons `< <= > >= = !=`;
* `error` is printed when a rule is unsafe or the program is not stratifiable.

The language and the output format are specified in `problems/datalog/SPEC.md`
of the surrounding workspace.

## Building

Requires LDC 1.41 and dub 1.40.

```sh
dub build -b release --compiler=ldc2    # builds bin/datalog
./build.sh                              # the same, from any directory
dub test --compiler=ldc2                # runs the unit tests
```

`dub.sdl` has three configurations: `cli` (the default; the executable),
`library` (just the library) and `unittest`. To depend on the library from
another dub project use `dependency "datalog" path="…" ` with
`subConfiguration "datalog" "library"`.

## Command-line use

The program reads one Datalog program from standard input and writes the
answers to standard output. It takes no arguments and always exits with 0.

```sh
$ cat > tc.dl <<'DL'
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
?- path(4, X).
DL
$ ./run.sh < tc.dl
path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
-- 0
```

For each query the matching tuples are printed in ascending order, one per
line, followed by `-- N` with the number of tuples. Queries are answered in
input order after the whole program has been read. If a rule is unsafe (a
variable of its head, a negated atom or a comparison does not occur in a
positive body atom) or the program has recursion through negation, the only
output is `error`.

## Library use

```d
import std.stdio;
import datalog;

void main()
{
    auto program = parseProgram(`
        parent(ann, bob). parent(bob, cy).
        ancestor(X, Y) :- parent(X, Y).
        ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).
        ?- ancestor(ann, X).
    `);

    auto model = new Model(program);        // checks and evaluates
    foreach (tuple; model.answer(program.queries[0]))
        writeln(tuple);                      // [ann, bob], [ann, cy]

    // Or go straight from text to the CLI's output format:
    write(solve("p(1). p(2). ?- p(X)."));
}
```

`Model`'s constructor throws `UnsafeRuleException` or
`StratificationException` (both `DatalogException`s); `parseProgram` throws
`ParseException`.

## Design

| module | responsibility |
| --- | --- |
| `datalog.lexer`, `datalog.parser` | text → `datalog.ast.Program` |
| `datalog.symbols` | `Constant`, its total order, interning; constants become dense *ranks* so that comparing constants is comparing integers |
| `datalog.analysis` | safety check; Tarjan SCCs of the predicate dependency graph give the strata and detect negative cycles |
| `datalog.relation` | a relation: row-major `uint` tuples, a hash set for duplicates, and hash indexes (one per set of bound columns) that are extended incrementally, never rebuilt per round |
| `datalog.plan` | compiles a rule into a join plan: delta atom first, then the atom with most bound arguments (ties in body order); comparisons and negations are applied as soon as their variables are bound |
| `datalog.exec` | runs a plan as an indexed nested-loop join |
| `datalog.engine` | `Model`: stratum by stratum, a first pass of every rule, then rounds in which each recursive atom in turn reads the previous round's new rows, atoms before it read only older rows and atoms after it read old and new rows; so every derivation is made once |
| `datalog.driver` | `solve`: program text → output text |
| `cli/app.d` | the command-line tool |

Rows are only ever appended, so "the delta of the last round" is a contiguous
row range and "old" rows are a prefix; no per-round copies are made.

## Tests

`dub test --compiler=ldc2` runs the `unittest` blocks of every module,
including the examples of the specification and a randomised comparison of the
engine against a naive reference evaluator (`datalog.crosscheck`).
