# datalog

A small Datalog engine with stratified negation, written in pure Python
(standard library only). It reads a program, checks that it is safe and
stratifiable, computes its perfect model by **semi-naive bottom-up
evaluation**, and answers the program's queries.

## Layout

```
src/datalog/
  syntax.py     AST (Atom, Literal, Comparison, Rule, Program) and constant ordering
  lexer.py      regex tokeniser
  parser.py     recursive-descent parser
  analysis.py   safety check, dependency graph, Tarjan SCCs, stratification
  relation.py   relations with incrementally maintained hash indexes
  planner.py    join-order selection and compilation of rules to join plans
  engine.py     semi-naive evaluation per component; Model with query()
  solve.py      solve(text) -> output text
  cli.py        command-line tool (python3 -m datalog)
tests/          pytest suite
```

How it works: constants are ranked once (integers before identifiers, ASCII
order), so all comparison and sorting is on plain ints. The dependency graph's
strongly connected components are evaluated in topological order; a negative
edge inside a component is an error. A non-recursive component runs each rule
once. A recursive component runs every rule once, then rounds in which, for
each positive body atom inside the component, a variant of the rule reads that
atom from the previous round's new tuples and the other atoms from the
relations as they stood at the start of the round. Each rule variant is
compiled to a Python nested-loop join (delta atom first, then the atom with the
most bound arguments), using hash indexes that are built once per access
pattern and extended as tuples are added.

## Build

There is no install step. Requires Python 3.14.

```
./build.sh        # byte-compiles the sources
```

(`pip install .` also works through the standard `pyproject.toml`.)

## Command line

```
./run.sh < program.dl
```

The whole of stdin is one program. For each query `?- p(...).` the matching
tuples are printed in ascending order, one `p(v1, v2)` per line, followed by
`-- N` with the count. If the program is unsafe or not stratifiable, `error`
is printed instead (exit status 0, reason on stderr). Malformed input is
reported the same way.

```
$ printf 'edge(1,2). edge(2,3).\npath(X,Y) :- edge(X,Y).\npath(X,Z) :- edge(X,Y), path(Y,Z).\n?- path(1, X).\n' | ./run.sh
path(1, 2)
path(1, 3)
-- 2
```

## Library

```python
from datalog import Atom, Variable, evaluate, parse

program = parse("""
    edge(1, 2). edge(2, 3). edge(3, 4).
    path(X, Y) :- edge(X, Y).
    path(X, Z) :- edge(X, Y), path(Y, Z).
    unreachable(X) :- node(X), not path(1, X).
    node(1). node(2). node(3). node(4). node(9).
""")
model = evaluate(program)        # raises UnsafeRuleError / StratificationError

model.relation("path", 2)        # [(1, 2), (1, 3), (1, 4), (2, 3), (2, 4), (3, 4)]
model.query(Atom("path", (1, Variable("X"))))   # [(1, 2), (1, 3), (1, 4)]
model.relation("unreachable", 1) # [(1,), (9,)]
```

Constants are Python `int`s and `str`s (identifiers). `datalog.solve(text)`
returns exactly the text the command-line tool prints (and raises
`DatalogError` subclasses instead of printing `error`).

## Tests

```
python3 -m pytest
```

The suite covers the lexer, parser, safety and stratification checks, the
engine, the CLI, and cross-checks the engine against a naive evaluator on
random stratified programs.
