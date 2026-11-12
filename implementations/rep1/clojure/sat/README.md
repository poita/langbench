# sat

A small CDCL SAT solver for DIMACS CNF, written in Clojure with no runtime
dependencies beyond Clojure itself.

It implements a MiniSat-style algorithm: two-watched-literal unit propagation,
first-UIP conflict analysis with local clause minimisation, VSIDS branching
(double-precision activities, decay 0.95 / 0.999) with phase saving, Luby
restarts (`100·luby(2, i)` conflicts) and periodic deletion of the
lower-activity half of the learnt clauses (binary clauses are always kept).
Input clauses are simplified at the root (duplicates, tautologies, satisfied
clauses, false literals, unit propagation).

## Layout

| Namespace      | Responsibility                                              |
|----------------|-------------------------------------------------------------|
| `sat.core`     | Public API: `solve`, `solve-dimacs`, `parse-dimacs`, ...    |
| `sat.dimacs`   | DIMACS parser and result formatter                          |
| `sat.solver`   | The CDCL engine                                             |
| `sat.heap`     | Indexed max-heap used as the VSIDS decision queue           |
| `sat.luby`     | The Luby restart sequence                                   |
| `sat.clause`   | Clause type (literals, activity, deletion mark)             |
| `sat.cli`      | Command-line entry point                                    |

## Build

Requires Clojure 1.12 (the `clojure` CLI) and a JDK.

```sh
./build.sh      # resolves dependencies and AOT-compiles sat.cli into classes/
```

## Command-line use

`run.sh` reads a DIMACS CNF file on standard input and prints either `UNSAT`,
or `SAT` followed by one line with a literal for every variable `1..V` and a
terminating `0`. The exit status is 0 in both cases.

```sh
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
$ printf 'p cnf 1 2\n1 0\n-1 0\n' | ./run.sh
UNSAT
```

Malformed input is reported on stderr with exit status 2.

## Library use

Add the project as a `deps.edn` dependency (e.g. `:local/root`), then:

```clojure
(require '[sat.core :as sat])

;; Literals are DIMACS-style: k = variable k true, -k = variable k false.
(sat/solve 3 [[1 -2] [2 3]])
;; => {:status :sat, :model [-1 -2 3], :conflicts 0, :decisions 1}

(sat/solve 1 [[1] [-1]])
;; => {:status :unsat, :conflicts 0, :decisions 0}

(let [clauses [[1 2] [-1 2] [-2 3]]
      {:keys [status model]} (sat/solve 3 clauses)]
  (and (= :sat status) (sat/satisfies? model clauses)))
;; => true

;; From DIMACS text, and back to the textual output format:
(-> "p cnf 2 2\n1 2 0\n-1 0\n" sat/solve-dimacs sat/format-result)
;; => "SAT\n-1 2 0\n"
```

`solve` returns `{:status :sat :model [...]}` where the model has one signed
literal per variable in increasing order, or `{:status :unsat}`. Both carry
`:conflicts` and `:decisions` statistics. Literals outside `1..num-vars` throw
`ex-info`.

## Tests

```sh
clojure -M:test      # Cognitect test-runner; unit tests + test.check properties
```

The properties compare the solver with brute-force enumeration on random small
formulas; further tests cover pigeonhole formulas, the parser and the heap.
