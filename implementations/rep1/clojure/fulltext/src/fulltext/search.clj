(ns fulltext.search
  "Running a query against an index: match, score, rank, snippet."
  (:require [fulltext.index :as index]
            [fulltext.matching :as matching]
            [fulltext.query :as query]
            [fulltext.scoring :as scoring]
            [fulltext.snippet :as snippet])
  (:import (java.util Arrays BitSet Comparator)
           (fulltext.matching AtomMatch)))

(set! *warn-on-reflection* true)

(def default-k
  "The default result limit."
  10)

(defn- frequency
  "f(a, d): occurrences of the atom match `m` in doc index `d` (0 if none)."
  ^long [^AtomMatch m ^long d]
  (let [i (Arrays/binarySearch ^ints (:docs m) (int d))]
    (if (neg? i) 0 (aget ^ints (:freqs m) i))))

(defn- score-docs
  "Score every doc of `matched` (a BitSet); returns [doc-indexes scores]
  as an int array and a parallel double array."
  [idx ^BitSet matched positive matches]
  (let [n (index/doc-count idx)
        avgdl (:avgdl idx)
        docs (:docs idx)
        cnt (.cardinality matched)
        ids (int-array cnt)
        scores (double-array cnt)
        ;; idf per positive atom, computed once
        atoms (mapv (fn [a]
                      (let [^AtomMatch m (get matches a)]
                        [m (scoring/idf n (alength ^ints (:docs m)))]))
                    positive)]
    (loop [d (.nextSetBit matched 0) i 0]
      (when (>= d 0)
        (let [dl (:length (nth docs d))
              s (reduce (fn [^double acc [m ^double idf]]
                          (let [f (frequency m d)]
                            (if (pos? f)
                              (+ acc (scoring/term-score idf f dl avgdl))
                              acc)))
                        0.0 atoms)]
          (aset ids i (int d))
          (aset scores i (double s))
          (recur (.nextSetBit matched (inc d)) (inc i)))))
    [ids scores]))

(defn- top-k
  "Doc indexes of the `k` best documents: score descending, doc index (hence
  id) ascending on ties."
  [^ints ids ^doubles scores ^long k]
  (let [order (object-array (range (alength ids)))]
    (Arrays/sort order
                 (reify Comparator
                   (compare [_ a b]
                     (let [sa (aget scores (int a)) sb (aget scores (int b))]
                       (cond
                         (> sa sb) -1
                         (< sa sb) 1
                         :else (Integer/compare (aget ids (int a))
                                                (aget ids (int b))))))))
    (mapv (fn [o] (let [i (int o)] [(aget ids i) (aget scores i)]))
          (take k order))))

(defn- snippet-for
  [idx positive matches d]
  (let [{:keys [text length starts ends]} (nth (:docs idx) d)
        occs (keep (fn [a]
                     (let [^AtomMatch m (get matches a)
                           i (Arrays/binarySearch ^ints (:docs m) (int d))]
                       (when (>= i 0)
                         [(count a) (aget ^objects (:starts m) i)])))
                   positive)
        s (snippet/best-window length occs)]
    (snippet/extract text starts ends s)))

(defn search-tree
  "Search `idx` with an already parsed query `tree`, returning at most `k`
  results as maps `{:rank :id :score :snippet}`, best first."
  [idx tree k]
  (let [matches (into {} (map (fn [a] [a (matching/match-atom idx a)]))
                      (query/atoms tree))
        positive (query/positive-atoms tree)
        matched (matching/evaluate (index/doc-count idx) matches tree)
        [ids scores] (score-docs idx matched positive matches)]
    (into []
          (map-indexed
           (fn [r [d score]]
             {:rank (inc r)
              :id (:id (nth (:docs idx) d))
              :score score
              :snippet (snippet-for idx positive matches d)}))
          (top-k ids scores k))))

(defn search
  "Parse `query-text` and search `idx`. Options: `:k` (default 10), the
  maximum number of results. Returns a vector of `{:rank :id :score :snippet}`
  maps, best first."
  ([idx query-text] (search idx query-text {}))
  ([idx query-text {:keys [k] :or {k default-k}}]
   (search-tree idx (query/parse query-text) k)))
