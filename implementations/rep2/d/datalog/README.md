# datalog

A Datalog engine with stratified negation, written in D. It reads a program
(facts, rules, queries), checks that it is safe and stratifiable, computes its
perfect model by **semi-naive bottom-up evaluation** and answers the queries.

* Library (`import datalog;`) split into lexer, parser, static analysis,
  tuple storage and evaluator modules.
* Command-line tool: program on stdin, answers on stdout.
* Only the D standard library is used; tests use D's built-in `unittest`.

## Language

```
edge(1, 2). edge(2, 3).                  % facts
path(X, Y) :- edge(X, Y).                % rules
path(X, Z) :- edge(X, Y), path(Y, Z).
lonely(X)  :- node(X), not path(X, _), X != none.   % negation, comparisons
?- path(1, X).                           % queries
```

Constants are integers (`-?[0-9]+`) or lowercase identifiers; variables start
with an uppercase letter; `_` is an anonymous variable. Built-in comparisons are
`< <= > >= = !=` over the total order *integers < identifiers* (integers
numerically, identifiers bytewise). Rules must be safe (every variable of the
head, of a negated atom or of a comparison occurs in a positive body atom) and
the predicate dependency graph must have no cycle through negation; otherwise
the output is just `error`.

For each query the matching tuples are printed in ascending order, one
`p(v1, v2)` per line, followed by `-- N` with their number.

## Build

Requires LDC and dub.

```
dub build -b release --compiler=ldc2     # or ./build.sh
```

This produces `bin/datalog`. Run the unit tests with

```
dub test --compiler=ldc2
```

## Command-line use

```
$ cat prog.dl
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(4, X).
?- path(X, X).
$ ./run.sh < prog.dl          # or bin/datalog < prog.dl
-- 0
path(1, 1)
path(2, 2)
path(3, 3)
-- 3
```

The exit status is 0 for valid and invalid programs alike (an invalid program
prints `error`).

## Library use

Add the package as a dependency (`dependency "datalog" path="..."`, which selects
the `library` configuration) and:

```d
import datalog;
import std.stdio;

void main()
{
    // One call: text in, text out ("error\n" is not returned; invalid programs throw).
    writeln(solve("p(1). p(2). q(X) :- p(X), X > 1. ?- q(X)."));

    // Step by step, with access to the model.
    auto program = parseProgram("e(a,b). e(b,c). t(X,Y) :- e(X,Y). t(X,Z) :- t(X,Y), e(Y,Z). ?- t(a, X).");
    checkSafety(program);                       // throws UnsafeRuleException
    auto strat = stratify(program);             // throws StratificationException
    auto model = evaluate(program, strat);
    foreach (ref q; program.queries)
        foreach (row; model.answer(q))          // sorted tuples of ranked values
            writeln(model.format(q.atom.pred, row));
}
```

`solveOrError` behaves like the CLI: it returns `"error\n"` instead of throwing.
All library exceptions derive from `DatalogException`.

## Layout

| module              | responsibility                                                    |
|---------------------|-------------------------------------------------------------------|
| `datalog.lexer`     | source text → tokens                                              |
| `datalog.parser`    | tokens → `Program` (`datalog.ast`)                                |
| `datalog.ast`       | syntax tree, constant interning and the order on constants        |
| `datalog.analysis`  | safety check; stratification (Tarjan SCCs)                        |
| `datalog.relation`  | tuple sets with incrementally maintained hash indexes             |
| `datalog.eval`      | join planning and semi-naive evaluation, query answering          |
| `datalog.solver`    | one-call `solve`, answer formatting                               |
| `datalog.cli`       | the command-line front end                                        |

## How evaluation works

Constants are ranked once in the language's total order, so every comparison
and every sort works on plain integers. Each rule is compiled to an indexed
nested-loop join: the delta atom first, then repeatedly the atom with the most
bound arguments; negations and comparisons run as soon as their variables are
bound. Components of the dependency graph are evaluated bottom-up; within a
recursive component each round runs one variant of a rule per recursive atom
(that atom reads the previous round's new tuples, earlier ones the old tuples,
later ones everything), so every derivation is made once. Hash indexes are
extended incrementally at the end of each round and never rebuilt.
