(ns sat.core
  "Public API of the SAT solver library.

      (require '[sat.core :as sat])
      (sat/solve 3 [[1 -2] [2 3]])
      ;=> {:status :sat, :model [-1 -2 3], ...}
      (sat/solve-dimacs \"p cnf 1 2\\n1 0\\n-1 0\\n\")
      ;=> {:status :unsat, ...}

  Literals follow the DIMACS convention: `k` is variable k (1-based) true,
  `-k` is false."
  (:require [sat.dimacs :as dimacs]
            [sat.solver :as solver]))

(defn solve
  "Decides satisfiability of a CNF formula over variables 1..`num-vars`.
  `clauses` is a sequence of sequences of non-zero integers.  Returns
  `{:status :sat :model [l1 ... lV]}` (one signed literal per variable, in
  order) or `{:status :unsat}`; both also carry `:conflicts` and `:decisions`
  statistics."
  [num-vars clauses]
  (solver/solve num-vars clauses))

(defn parse-dimacs
  "Parses DIMACS CNF text (String or Reader) into `{:num-vars V :clauses [...]}`."
  [in]
  (dimacs/parse in))

(defn solve-dimacs
  "Parses DIMACS CNF text (String or Reader) and solves it."
  [in]
  (let [{:keys [num-vars clauses]} (dimacs/parse in)]
    (solve num-vars clauses)))

(defn format-result
  "Renders a result of [[solve]] in the textual output format (`SAT`/`UNSAT`)."
  [result]
  (dimacs/format-result result))

(defn satisfies?
  "True when `model` (a seq of signed literals, one per variable) satisfies
  every clause in `clauses`."
  [model clauses]
  (let [true-lits (set model)]
    (every? (fn [c] (some true-lits c)) clauses)))
