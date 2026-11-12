(ns datalog.eval
  "Bottom-up, semi-naive evaluation of a stratified program.

  `solve` checks safety and stratifiability, interns every constant to its
  rank in the global constant order, loads the facts, and then evaluates the
  strongly connected components of the dependency graph from the lowest
  stratum up:

  * a component's rules are run once on the relations as they stand;
  * for a recursive component, rounds follow in which each rule is run once
    per positive atom of the component, reading that atom from the delta of
    the previous round (see `datalog.plan`), until a round derives nothing."
  (:require [datalog.analysis :as an]
            [datalog.plan :as plan]
            [datalog.join :as j]
            [datalog.storage :as st]
            [datalog.syntax :as syn])
  (:import (datalog.storage IRelation)))

(set! *warn-on-reflection* true)

(defrecord Model
  [relations   ; predicate key [name arity] -> relation
   constants   ; id -> constant, in ascending constant order
   ids])       ; constant -> id

(defn- program-constants
  "All constants occurring anywhere in the program."
  [{:keys [rules queries]}]
  (let [atoms (concat (map :head rules)
                      (keep :atom (mapcat :body rules))
                      queries)
        cmps (filter #(= :cmp (:op %)) (mapcat :body rules))]
    (into #{}
          (filter syn/constant?)
          (concat (mapcat :args atoms)
                  (mapcat (juxt :left :right) cmps)))))

(defn- program-pred-keys [{:keys [rules queries]}]
  (into #{}
        (concat (map (comp syn/atom-key :head) rules)
                (map syn/atom-key (keep :atom (mapcat :body rules)))
                (map syn/atom-key queries))))

(defn- run-component!
  "Evaluates the rules of one component to their least fixpoint."
  [rules comp-keys {:keys [rel-of] :as ctx}]
  (let [comp-set (set comp-keys)
        rels (mapv rel-of comp-keys)
        commit-all! (fn [] (doseq [^IRelation r rels] (.commit r)))
        full (mapv #(plan/compile-rule % ctx nil) rules)
        deltas (vec (for [rule rules
                          [i k] (map-indexed vector (plan/positive-atom-keys rule))
                          :when (contains? comp-set k)]
                      {:rel (rel-of k)
                       :exec (plan/compile-rule rule ctx i)}))]
    (run! j/execute! full)
    (commit-all!)
    (when (seq deltas)
      (loop []
        (when (some (fn [^IRelation r] (< (.deltaLo r) (.deltaHi r))) rels)
          (doseq [{:keys [^IRelation rel exec]} deltas]
            (when (< (.deltaLo rel) (.deltaHi rel))
              (j/execute! exec)))
          (commit-all!)
          (recur))))))

(defn solve
  "Computes the perfect model of `program` (see `datalog.syntax`) and returns
  a `Model`. Throws an `ex-info` with `:type` `:datalog/unsafe-rule` or
  `:datalog/not-stratifiable` when the program is not safe or not
  stratifiable."
  [{:keys [rules] :as program}]
  (an/check-safety! rules)
  (let [components (an/stratify rules)
        consts (vec (sort syn/compare-constants (program-constants program)))
        ids (into {} (map-indexed (fn [i c] [c i])) consts)
        relations (into {} (map (fn [[_ arity :as k]] [k (st/make-relation arity)]))
                        (program-pred-keys program))
        ctx {:rel-of relations :id-of ids}
        {facts true proper false} (group-by syn/fact? rules)
        by-head (group-by (comp syn/atom-key :head) proper)]
    (doseq [{:keys [head]} facts]
      (.add ^IRelation (relations (syn/atom-key head))
            (int-array (map ids (:args head)))))
    (doseq [^IRelation r (vals relations)] (.commit r))
    (doseq [comp components
            :let [crules (vec (mapcat by-head comp))]
            :when (seq crules)]
      (run-component! crules comp ctx))
    (->Model relations consts ids)))
