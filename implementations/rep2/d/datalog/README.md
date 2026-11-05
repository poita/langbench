# datalog

A Datalog engine with stratified negation, written in D using only Phobos.
It reads a program (facts, rules, queries) and prints the answers to its queries
under the standard perfect-model semantics, or `error` if the program is unsafe
or not stratifiable.

Evaluation is bottom-up and semi-naive: constants are interned to
order-preserving integer ids, relations are append-only tuple arrays with a hash
set for deduplication, join plans use lazily built, incrementally extended hash
indexes, and each strongly connected component of the predicate graph is
evaluated in topological order.

## Build

Requires LDC and dub (developed with LDC 1.41.0, dub 1.40.0).

```
./build.sh                                  # builds bin/datalog
# or directly:
dub build -b release --compiler=ldc2
dub test --compiler=ldc2                    # unit tests
```

## Command line

```
./run.sh < program.dl
```

The whole of stdin is the program; stdout receives, for each query in order, the
matching tuples in ascending order followed by `-- N`. If a rule is unsafe or
the program is not stratifiable the only output is `error`. The exit code is 0
in both cases (2 on a syntax error, with a message on stderr).

```
$ ./run.sh <<'EOT'
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
EOT
path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
```

Language summary: identifiers `[a-z][a-z0-9_]*` and integers are constants
(integers sort before identifiers, identifiers bytewise); variables start with
an upper-case letter; `_` is an anonymous variable; body literals are atoms,
`not atom`, and comparisons `< <= > >= = !=`; `%` starts a comment; queries are
`?- atom.` See `problems/datalog/SPEC.md` for the full specification.

## Library

Layout (`source/datalog/`):

| module     | responsibility                                                   |
|------------|------------------------------------------------------------------|
| `lexer`    | tokeniser                                                        |
| `parser`   | one-pass parser, interning, order-preserving constant renumbering |
| `ast`      | `Program`, `Rule`, `Atom`, `Literal`, `Term`, …                  |
| `analysis` | safety check, SCCs, stratification, evaluation order             |
| `relation` | `Relation` (tuples + hash set) and `Index` (hash index)          |
| `plan`     | compiling rules into join plans (full and per-atom delta variants) |
| `engine`   | `Database.evaluate`: semi-naive evaluation                       |
| `query`    | `matchQuery`, `renderAnswers`                                    |
| `errors`   | `ParseException`, `ProgramError`                                 |

`import datalog;` pulls in everything. Example:

```d
import std.stdio;
import datalog;

void main()
{
    auto program = parseProgram(`
        parent(alice, bob). parent(bob, carol).
        anc(X, Y) :- parent(X, Y).
        anc(X, Z) :- parent(X, Y), anc(Y, Z).
        ?- anc(alice, X).
    `);

    // Static checks are also available on their own.
    assert(analyze(program).status == Status.ok);

    auto db = Database.evaluate(program);       // throws ProgramError if unsafe/unstratifiable
    write(renderAnswers(db));
    // anc(alice, bob)
    // anc(alice, carol)
    // -- 2

    // Or query programmatically: flat array of constant ids, stride = arity.
    auto flat = matchQuery(db, program.queries[0]);
    writeln(program.constants[flat[1]]);        // bob
}
```

`solve(string source)` runs the whole pipeline and returns the CLI's output.

Limits: predicate arity is at most 32 (`datalog.relation.maxArity`); a relation
holds fewer than 2^32 tuples.

## Tests

Unit tests live in `tests/datalog_tests/` (lexer, parser, analysis, relation,
engine) and run with `dub test --compiler=ldc2`. The end-to-end suite is run with
`python3 run_tests.py datalog -- datalog/run.sh` from the repository root.
