# datalog

A small Datalog engine with stratified negation, written in pure Python
(standard library only). It reads a program, checks that every rule is safe and
that the program is stratifiable, computes the perfect model by bottom-up
**semi-naive evaluation**, and answers the queries in the program.

* integers and identifiers as constants, with the total order *integers < identifiers*;
* positive and negated body atoms, and the comparisons `< <= > >= = !=`;
* recursion, including non-linear and mutual recursion;
* hash indexes per access pattern, built once and maintained incrementally;
* every rule is compiled once into a specialised nested-loop join (generated Python).

## Build and test

There is nothing to compile; `build.sh` only byte-compiles the package.

```sh
./build.sh                 # byte-compile src/
python3 -m pytest          # run the test-suite (needs pytest)
```

The package is described by `pyproject.toml` (setuptools backend, `src/` layout);
`pip install .` installs a `datalog` command, but is not required.

## Command line

`run.sh` reads a whole program on stdin and writes the answers to stdout:

```sh
$ printf 'edge(1,2). edge(2,3).
path(X,Y) :- edge(X,Y).
path(X,Z) :- edge(X,Y), path(Y,Z).
?- path(1, X).
' | ./run.sh
path(1, 2)
path(1, 3)
-- 2
```

For each query it prints the matching tuples in ascending order, one per line,
then `-- N`. A program that is unsafe or not stratifiable prints just `error`.
The exit status is 0 in both cases. The input language and output format are
specified in `problems/datalog/SPEC.md`.

## Library

```python
import datalog

program = datalog.parse("""
    node(a). node(b). node(c).
    link(a, b). link(b, c).
    reach(X, Y) :- link(X, Y).
    reach(X, Z) :- reach(X, Y), link(Y, Z).
    sink(X) :- node(X), not has_out(X).
    has_out(X) :- link(X, _).
""")
model = datalog.evaluate(program)      # may raise UnsafeRuleError / StratificationError

model.query("reach(a, X)")             # [('a', 'b'), ('a', 'c')]
model.relation("sink", 1)              # [('c',)]
datalog.run("p(1). ?- p(X).")          # 'p(1)\n-- 1\n'   (text in, CLI output out)
```

Constants come back as Python `int` or `str`; results are sorted by the
Datalog constant order.

### Modules

| module | responsibility |
| --- | --- |
| `syntax` | immutable AST: `Var`, `Const`, `Atom`, `Not`, `Comparison`, `Rule`, `Query`, `Program` |
| `parser` | tokeniser and recursive-descent parser (`parse`, `parse_atom`) |
| `analysis` | safety check; predicate dependency graph, Tarjan SCCs, stratification |
| `constants` | the total order on constants as dense integer ranks |
| `relation` | tuple sets with incrementally maintained hash indexes |
| `planner` | join order (delta atom first, then most bound arguments) and filter placement |
| `codegen` | compiles a plan into a specialised Python function |
| `engine` | semi-naive evaluation per component; `Model` for querying |
| `api`, `cli` | output formatting and the command-line entry point |

## Algorithm

Predicates are grouped into strongly connected components of the dependency
graph, and a negative edge inside a component means the program is not
stratifiable. Components are evaluated in dependency order. Rules that do not
read their own component run once; the others run in rounds in which each
recursive body atom in turn reads only the previous round's new tuples (the
delta) while the remaining atoms read the full relations, until a round derives
nothing.
