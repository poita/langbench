(ns datalog.eval
  "Bottom-up semi-naive evaluation of a stratified program.

  The strata are the strongly connected components of the predicate
  dependency graph, taken in dependency order (see
  [[datalog.analysis/stratify]]).  A component is evaluated as follows.

  1. *Round 0* runs every rule once over the relations as they are.
  2. If some rule has a positive body atom whose predicate is in the
     component, rounds 1, 2, ... follow.  Round `k` runs, for each such rule
     and for each such atom, a variant of the rule that reads that atom from
     the *delta* (the tuples added in round `k-1`) and every other atom from
     the relations as they stood at the start of the round.
  3. Evaluation stops when a round adds nothing.

  Every tuple is therefore the delta of exactly one round.  Relations are
  frozen at the start of each round (see [[datalog.relation/freeze!]]), so
  tuples derived during a round only become visible in the next one."
  (:require [datalog.analysis :as analysis]
            [datalog.constants :as constants]
            [datalog.plan :as plan]
            [datalog.relation :as rel]))

(set! *warn-on-reflection* true)

(defn- clause-constants [clauses]
  (let [terms (fn [atom] (:args atom))]
    (for [c clauses
          t (case (:type c)
              :query (terms (:atom c))
              :rule (concat (terms (:head c))
                            (mapcat #(if (= :cmp (:kind %)) [(:left %) (:right %)] (terms %))
                                    (:body c))))
          :when (not (symbol? t))]
      t)))

(defn- run-component!
  "Evaluates the rules `rules` (lowered) whose heads are the predicates `preds`
  of one component."
  [rules preds relations boxed all-rels]
  (let [in-comp? (set preds)
        round0 (mapv #(plan/compile-variant % relations boxed nil) rules)
        delta-variants
        (vec (for [rule rules
                   [i atom] (map-indexed vector (:atoms rule))
                   :when (in-comp? (:pid atom))]
               {:pid (:pid atom)
                :run (plan/compile-variant rule relations boxed i)}))
        sizes #(into {} (map (fn [p] [p (rel/size (relations p))])) preds)]
    (doseq [r all-rels] (rel/freeze! r))
    (let [before (sizes)]
      (doseq [run round0] (run 0 0))
      (when (seq delta-variants)
        (loop [prev before]
          (doseq [r all-rels] (rel/freeze! r))
          (let [cur (sizes)]
            (when (not= prev cur)
              (doseq [{:keys [pid run]} delta-variants]
                (let [lo (prev pid), hi (cur pid)]
                  (when (< lo hi) (run lo hi))))
              (recur cur))))))))

(defn evaluate
  "Computes the stratified model of `clauses` (parsed, assumed safe and
  stratifiable, with `strata` from [[datalog.analysis/stratify]]).

  Returns `{:relations {pred-id Relation}, :table intern-table}`, where tuples
  hold ranks and the table (see [[datalog.constants/intern-table]]) maps them
  back to constants."
  [clauses strata]
  (let [{:keys [constants rank] :as table} (constants/intern-table (clause-constants clauses))
        boxed (object-array (map #(Long/valueOf (long %)) (range (count constants))))
        relations (into {} (map (fn [p] [p (rel/make-relation)]))
                        (:nodes (analysis/dependency-graph clauses)))
        rules (for [c clauses :when (= :rule (:type c))] c)
        {facts true proper false} (group-by #(empty? (:body %)) rules)
        all-rels (vec (vals relations))]
    ;; Facts go in first; they are part of the relations when round 0 starts.
    (doseq [{:keys [head]} facts]
      (rel/add! (relations (analysis/pred-id head))
                (vec (map #(Long/valueOf (long (rank %))) (:args head)))))
    (let [by-head (group-by #(analysis/pred-id (:head %)) proper)]
      (doseq [preds strata
              :let [rs (mapv #(plan/lower-rule % rank) (mapcat by-head preds))]
              :when (seq rs)]
        (run-component! rs preds relations boxed all-rels)))
    {:relations relations :table table}))
