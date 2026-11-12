# sat — a CDCL SAT solver in Clojure

`sat` decides satisfiability of propositional formulas in conjunctive normal
form. It is a MiniSat-style conflict-driven clause-learning solver written in
plain Clojure (no dependencies beyond Clojure itself), packaged as a small
library plus a DIMACS command-line tool.

Techniques: two-watched-literal unit propagation, first-UIP clause learning
with local minimisation, VSIDS branching (indexed binary heap, activities
decayed by 0.95 / 0.999 and rescaled on overflow), phase saving, Luby restarts
(unit 100 conflicts) and periodic deletion of the low-activity half of the
learnt clauses.

Requires Clojure 1.12 (the `clojure` CLI) and a JDK (developed on Java 27).

## Build

```
./build.sh
```

AOT-compiles the CLI into `target/classes` and records the runtime classpath in
`target/classpath` (this avoids the Clojure CLI's startup cost on every run).

## Command-line use

`run.sh` reads a DIMACS CNF file on stdin and prints the answer on stdout; it
always exits 0 for a well-formed input.

```
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
$ printf 'p cnf 1 2\n1 0\n-1 0\n' | ./run.sh
UNSAT
```

On `SAT` the second line holds one literal per variable `1..V` (negative =
false) followed by `0`. Comments, blank lines, clauses spanning lines and
several clauses per line are accepted.

Without building you can also run `clojure -M:run < problem.cnf`.

## Library use

Clauses are collections of non-zero integers (DIMACS style: `k` is variable
`k`, `-k` its negation).

```clojure
(require '[sat.core :as sat] '[sat.dimacs :as dimacs])

(sat/solve [[1 -2] [2 3]])
;=> {:status :sat, :model [-1 -2 3], :stats {:conflicts 0, ...}}

(sat/solve [[1] [-1]])
;=> {:status :unsat, :stats {...}}

(sat/solve 5 [[1 2]])            ; explicit variable count; unused vars are assigned too
(sat/satisfiable? [[1 2] [-1]])  ;=> true
(sat/satisfies? [-1 2] [[1 2] [-1]]) ;=> true  (checks a model against clauses)

;; DIMACS text in, DIMACS-style answer out
(let [{:keys [num-vars clauses]} (dimacs/parse "p cnf 2 2\n1 2 0\n-1 0\n")]
  (print (dimacs/format-result (sat/solve num-vars clauses))))
;; SAT
;; -1 2 0
```

### Modules

| Namespace      | Responsibility |
|----------------|----------------|
| `sat.core`     | Public API: `solve`, `satisfiable?`, `satisfies?` |
| `sat.dimacs`   | `parse` DIMACS text, `format-result` for the CLI output |
| `sat.solver`   | The mutable CDCL engine (`new-solver`, `add-clause!`, `solve!`, `model`, `stats`) |
| `sat.heap`     | Indexed max-heap used as the VSIDS priority queue |
| `sat.luby`     | The Luby restart sequence |
| `sat.cli`      | `-main`: stdin/stdout driver |

## Tests

```
clojure -X:test
```

Runs the unit tests and the `test.check` properties (the solver is checked
against brute-force enumeration on random small formulas) with the Cognitect
test-runner.
