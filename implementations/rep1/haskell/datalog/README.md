# datalog

A Datalog engine with stratified negation, written in Haskell. It is a small
library plus a command-line tool: the tool reads a program on standard input,
computes its perfect model and answers every query in it.

Only GHC's bundled packages (`base`, `containers`, `array`, `bytestring`) are
used; the tests additionally use `hspec` and `QuickCheck`.

## Language

```prolog
edge(1, 2). edge(2, 3).                  % facts
path(X, Y) :- edge(X, Y).                % rules
path(X, Z) :- edge(X, Y), path(Y, Z).
sink(X) :- node(X), not hasout(X).       % stratified negation
small(X) :- node(X), X < a.              % comparisons: < <= > >= = !=
?- path(1, X).                           % queries
```

Constants are integers or lowercase identifiers (all integers sort before all
identifiers; identifiers sort bytewise). Variables start with an uppercase
letter; `_` is an anonymous variable. A predicate is identified by name and
arity. A program is rejected with the single output line `error` when a rule
is unsafe (a variable of the head, a negated atom or a comparison does not
occur in a positive body atom) or when a cycle of the predicate dependency
graph contains a negative edge. See `problems/datalog/SPEC.md` for the full
specification.

## Build

```
./build.sh          # cabal build, then copies the executable to bin/datalog
cabal test          # unit, property and golden tests
```

Requires GHC 9.14 and cabal 3.18.

## Command line

```
./run.sh < program.dl
```

Each query prints its matching tuples in ascending order, one per line, then
`-- N` with the number of tuples. Example:

```
$ printf 'edge(1,2). edge(2,3). p(X,Y) :- edge(X,Y). p(X,Z) :- edge(X,Y), p(Y,Z). ?- p(1,X).' | ./run.sh
p(1, 2)
p(1, 3)
-- 2
```

The exit code is 0 for a program that is answered or rejected with `error`;
syntactically malformed input prints a message to stderr and exits 1.

## Library

```haskell
import qualified Data.ByteString.Char8 as B
import Datalog

main :: IO ()
main = do
  let src = B.pack "edge(1,2). edge(2,3). \
                   \path(X,Y) :- edge(X,Y). path(X,Z) :- edge(X,Y), path(Y,Z)."
  prog  <- either (fail . show) pure (parseProgram src)
  model <- either (fail . show) pure (evaluate prog)
  print (queryModel model (Atom (B.pack "path") [TConst (CInt 1), TVar (B.pack "X")]))
  -- [[CInt 1,CInt 2],[CInt 1,CInt 3]]
```

`runSource :: ByteString -> Either ParseError Builder` does everything the
command-line tool does.

| module              | responsibility                                                     |
|---------------------|--------------------------------------------------------------------|
| `Datalog`           | public API re-exporting the modules below                          |
| `Datalog.Syntax`    | AST, the total order on constants, comparison semantics           |
| `Datalog.Parser`    | lexer and recursive-descent parser                                 |
| `Datalog.Analysis`  | safety check; SCCs of the dependency graph and stratification      |
| `Datalog.Trie`      | persistent tuple sets (nested `IntMap`s) used for relations/indexes|
| `Datalog.Plan`      | compiles rules into join plans (join order, bound/free columns)    |
| `Datalog.Eval`      | semi-naive evaluation, indexes, queries                            |
| `Datalog.Render`    | output formatting                                                  |

## How it works

Constants are numbered by their rank in the total order, so comparisons are
integer comparisons and tries enumerate in output order. Predicates are
grouped into strongly connected components, evaluated in dependency order. A
recursive component runs each rule once, then rounds in which every rule runs
once per recursive positive atom with that atom reading the previous round's
new tuples (semi-naive); the other atoms read the relations as they stood at
the start of the round. A rule's join is an indexed nested loop: delta atom
first, then the atom with most bound arguments, with negations and
comparisons applied as soon as their variables are bound. Each relation keeps
one trie per access pattern, extended (never rebuilt) with each round's new
tuples.

## Tests

`cabal test` runs: parser and analysis unit tests, the specification's
examples, properties for the trie, a QuickCheck cross-check of the engine
against an independent naive evaluator (`test/Reference.hs`) on random
programs, and golden programs in `test/golden/`.
