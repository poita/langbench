(ns sat.core
  "Public API of the CDCL SAT solver.

  Clauses are collections of non-zero integers in DIMACS style: `k` is
  variable k (1-based) and `-k` its negation.

      (require '[sat.core :as sat])
      (sat/solve [[1 -2] [2 3]])
      ;=> {:status :sat, :model [-1 -2 3], :stats {...}}
      (sat/solve [[1] [-1]])
      ;=> {:status :unsat, :stats {...}}"
  (:refer-clojure :exclude [satisfies?])
  (:require [sat.solver :as solver]))

(defn solve
  "Decides satisfiability of the CNF formula `clauses`.

  `num-vars`, if given, is the number of variables (every literal must lie in
  `1..num-vars`); otherwise it is the largest variable occurring in `clauses`.
  Variables that occur in no clause are still assigned in the model.

  Returns `{:status :sat :model m :stats s}` or `{:status :unsat :stats s}`
  where `m` is a vector of `num-vars` signed literals, one per variable in
  increasing order (so `(nth m (dec k))` is `k` or `-k`)."
  ([clauses]
   (solve (reduce (fn [m c] (reduce (fn [m l] (max m (Math/abs (long l)))) m c)) 0 clauses)
          clauses))
  ([num-vars clauses]
   (let [s (solver/new-solver num-vars)]
     (loop [cs (seq clauses)]
       (if (and cs (solver/add-clause! s (first cs)))
         (recur (next cs))
         (let [status (if cs :unsat (solver/solve! s))]
           (cond-> {:status status :stats (solver/stats s)}
             (= status :sat) (assoc :model (solver/model s)))))))))

(defn satisfiable?
  "True iff the formula is satisfiable."
  ([clauses] (= :sat (:status (solve clauses))))
  ([num-vars clauses] (= :sat (:status (solve num-vars clauses)))))

(defn satisfies?
  "True iff `model` (a collection of signed literals, as returned by `solve`)
  satisfies every clause in `clauses`. Variables missing from the model count
  as unassigned (their literals are not satisfied)."
  [model clauses]
  (let [true-lits (set model)]
    (every? (fn [clause] (some true-lits clause)) clauses)))
