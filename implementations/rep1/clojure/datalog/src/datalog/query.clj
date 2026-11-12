(ns datalog.query
  "Answering queries against a solved `datalog.eval/Model`."
  (:require [datalog.syntax :as syn])
  (:import (datalog.storage IIndex IRelation)))

(set! *warn-on-reflection* true)

(defn answers
  "The tuples of the model matching `query-atom`, as a vector of vectors of
  constants in ascending tuple order. Constants must equal the tuple's
  component; a variable occurring several times must match the same constant
  everywhere; `_` and variables occurring once match anything. Unknown
  predicates and constants that occur nowhere in the program match nothing."
  [{:keys [relations constants ids]} query-atom]
  (let [^IRelation rel (get relations (syn/atom-key query-atom))
        args (:args query-atom)
        ;; [column id] for constants, nil if one is unknown
        consts (keep-indexed (fn [c t] (when (syn/constant? t) [c (get ids t)])) args)
        ;; [col col] pairs forced equal by a repeated named variable
        eqs (let [first-col (volatile! {})]
              (vec (keep-indexed
                    (fn [c t]
                      (when (and (symbol? t) (not (syn/anonymous? t)))
                        (if-let [c0 (get @first-col t)]
                          [c0 c]
                          (do (vswap! first-col assoc t c) nil))))
                    args)))]
    (if (or (nil? rel) (some (comp nil? second) consts))
      []
      (let [data (.data rel)
            arity (.arity rel)
            keep-id? (fn [^long id]
                       (let [base (* id arity)]
                         (every? (fn [[a b]] (== (aget data (+ base (long a)))
                                                 (aget data (+ base (long b)))))
                                 eqs)))
            candidates (if (empty? consts)
                         (range (.visible rel))
                         (let [^IIndex ix (.indexOn rel (int-array (map first consts)))
                               key (int-array (map second consts))]
                           (take-while #(>= (long %) 0)
                                       (iterate #(.chainNext ix (long %))
                                                (.lookup ix data key)))))]
        (->> candidates
             (filter keep-id?)
             (map (fn [^long id]
                    (let [base (* id arity)]
                      (vec (for [c (range arity)] (aget data (+ base (long c))))))))
             (sort compare)
             (mapv (fn [r] (mapv #(nth constants %) r))))))))
