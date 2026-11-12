# datalog

A small Datalog engine with stratified negation, written in Haskell using only
GHC's bundled libraries (`base`, `array`, `containers`).

It reads a program (facts, rules, queries), rejects it if it is unsafe or not
stratifiable, computes the perfect model bottom-up with **semi-naive
evaluation**, and answers the queries in order.

## Language

```prolog
% facts, rules, queries; `_` is an anonymous variable
edge(1, 2). edge(2, 3).
path(X, Y) :- edge(X, Y).
path(X, Z) :- path(X, Y), edge(Y, Z).
unreached(X) :- node(X), not path(1, X), X != 1.
?- path(1, X).
```

* Constants are integers or lower-case identifiers; variables start with an
  upper-case letter. Predicates are identified by name *and* arity.
* Body literals: positive atoms, `not atom`, and comparisons
  `< <= > >= = !=`. Integers order before identifiers; identifiers order like
  `strcmp`.
* A rule is *safe* if every variable in its head, a negated atom or a
  comparison also occurs in a positive body atom. A program is *stratifiable*
  if no dependency cycle goes through a negation.

## Build

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build, then copies the executable to bin/datalog
cabal test          # unit tests, plus a property test against a naive oracle
```

## Command line

`datalog` reads one program on stdin and writes to stdout (exit status is 0
either way):

```sh
$ printf 'e(1,2). e(2,3). p(X,Y):-e(X,Y). p(X,Z):-p(X,Y),e(Y,Z). ?- p(1,X).' | ./run.sh
p(1, 2)
p(1, 3)
-- 2
```

For every query the matching tuples are printed in ascending order, one per
line as `pred(v1, v2, …)`, followed by `-- N`. If the program is unsafe or not
stratifiable the only output is `error`.

## Library

```haskell
import Datalog

main :: IO ()
main = do
  let src = "e(1,2). e(2,3). p(X,Y):-e(X,Y). p(X,Z):-p(X,Y),e(Y,Z). ?- p(1,X)."
  case runProgram src of
    Left err      -> putStrLn ("failed: " ++ show err)
    Right results -> do
      putStr (renderResults results)
      -- or inspect them: qrTuples gives [[Const]]
      print [map renderConst t | r <- results, t <- qrTuples r]
```

The stages are available separately: `parseProgram`, `check` (safety, then
stratification; returns the components in evaluation order), `evaluate`
(builds a `Model`), `queryModel` and `modelTuples`.

| module                 | responsibility                                          |
|------------------------|---------------------------------------------------------|
| `Datalog`              | one-call interface and re-exports                       |
| `Datalog.Syntax`       | AST, constant ordering, rendering                       |
| `Datalog.Parser`       | tokeniser and parser                                    |
| `Datalog.Analysis`     | safety check, dependency graph, SCCs / stratification   |
| `Datalog.Eval`         | semi-naive evaluation of each stratum                   |
| `Datalog.Model`        | the computed model and query matching                   |
| `Datalog.Internal.*`   | hash-indexed relations and join-plan compilation (not exposed) |

## Implementation notes

* Constants are interned to their rank in the total order, so comparisons and
  sorting work on `Int`s.
* A relation is a flat unboxed array of rows plus chained hash indexes, one
  per set of bound columns used by some join; each index is maintained
  incrementally (O(rows) in total, never rebuilt per round).
* Each rule is compiled to an indexed nested-loop join; negations and
  comparisons run as soon as their variables are bound. In a recursive
  stratum a rule gets one variant per recursive body atom: that atom reads the
  previous round's delta, earlier recursive atoms read only older rows and
  later ones read everything, so each derivation is made once. Join order:
  delta atom first, then most bound arguments, ties in body order.
