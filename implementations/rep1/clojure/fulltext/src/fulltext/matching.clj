(ns fulltext.matching
  "Matching atoms against the index and evaluating boolean queries.

  [[match-atom]] finds every occurrence of a (phrase) atom by intersecting
  the position lists of its terms; [[evaluate]] runs the query tree as set
  algebra over documents, using `java.util.BitSet`s indexed by doc index."
  (:require [fulltext.index :as index])
  (:import (java.util BitSet)
           (fulltext.index Postings)))

(set! *warn-on-reflection* true)

(defrecord AtomMatch
  [docs    ; int[]    — sorted doc indexes in which the atom occurs
   starts  ; Object[] — parallel to docs; int[] of sorted occurrence starts
   freqs]) ; int[]    — parallel to docs; number of occurrences

(def ^:private no-match (->AtomMatch (int-array 0) (object-array 0) (int-array 0)))

(defn- bisect
  "Smallest index in [lo, hi] whose element is >= x, assuming arr[hi] >= x
  (or hi = length)."
  ^long [^ints arr ^long lo ^long hi ^long x]
  (loop [lo lo hi hi]
    (if (< lo hi)
      (let [mid (+ lo (quot (- hi lo) 2))]
        (if (< (aget arr mid) x)
          (recur (inc mid) hi)
          (recur lo mid)))
      lo)))

(defn- advance
  "Smallest index `i' >= i` with `arr[i'] >= x`, or `(alength arr)`. Gallops
  forward from `i` and then bisects, so repeated forward searches over one
  array cost O(log gap) each."
  ^long [^ints arr ^long i ^long x]
  (let [n (alength arr)]
    (if (or (>= i n) (>= (aget arr i) x))
      i
      ;; Invariant: arr[lo] < x.
      (loop [lo i step 1]
        (let [j (+ lo step)]
          (cond
            (>= j n) (bisect arr (inc lo) n x)
            (>= (aget arr j) x) (bisect arr (inc lo) j x)
            :else (recur j (* 2 step))))))))

(defn- phrase-positions
  "Start positions of the phrase in one document, given each term's sorted
  position array (`pos-lists`, one per term, in phrase order). A start `p`
  qualifies when term `i` occurs at `p + i` for every `i`. Linear in the
  lengths of the lists (one forward-moving cursor per term)."
  ^ints [^objects pos-lists]
  (let [k (alength pos-lists)
        ^ints first-list (aget pos-lists 0)
        out (int-array (alength first-list))
        cursors (long-array k)]
    (loop [a 0 cnt 0]
      (if (< a (alength first-list))
        (let [p (aget first-list a)
              ok? (loop [i 1]
                    (if (< i k)
                      (let [^ints li (aget pos-lists i)
                            want (+ p i)
                            c (advance li (aget cursors i) want)]
                        (aset cursors i c)
                        (if (and (< c (alength li)) (== (aget li c) want))
                          (recur (inc i))
                          false))
                      true))]
          (if ok?
            (do (aset out cnt p) (recur (inc a) (inc cnt)))
            (recur (inc a) cnt)))
        (java.util.Arrays/copyOf out (int cnt))))))

(defn match-atom
  "All occurrences of `terms` (a vector of terms, in phrase order) in the
  index, as an [[AtomMatch]]. Returns an empty match when some term is absent
  from the index."
  [idx terms]
  (let [posts (mapv #(index/postings idx %) terms)]
    (if (some nil? posts)
      no-match
      (let [k (count posts)
            ^Postings p0 (first posts)]
        (if (== k 1)
          (let [^objects ps (:positions p0)
                freqs (int-array (alength ps))]
            (dotimes [i (alength ps)]
              (aset freqs i (alength ^ints (aget ps i))))
            (->AtomMatch (:docs p0) ps freqs))
          ;; Walk the first term's documents; for each, find the same doc in
          ;; every other term's doc list with a forward-moving cursor.
          (let [^ints d0 (:docs p0)
                other-docs (object-array (map :docs (rest posts)))
                cursors (long-array (dec k))
                pos-lists (object-array k)
                docs-out (java.util.ArrayList.)
                starts-out (java.util.ArrayList.)
                freqs-out (java.util.ArrayList.)]
            (dotimes [a (alength d0)]
              (let [d (aget d0 a)
                    ok? (loop [j 0]
                          (if (< j (dec k))
                            (let [^ints dj (aget other-docs j)
                                  c (advance dj (aget cursors j) d)]
                              (aset cursors j c)
                              (if (and (< c (alength dj)) (== (aget dj c) d))
                                (do (aset pos-lists (inc j)
                                          (aget ^objects (:positions (nth posts (inc j))) c))
                                    (recur (inc j)))
                                false))
                            true))]
                (when ok?
                  (aset pos-lists 0 (aget ^objects (:positions p0) a))
                  (let [found (phrase-positions pos-lists)]
                    (when (pos? (alength found))
                      (.add docs-out (int d))
                      (.add starts-out found)
                      (.add freqs-out (int (alength found))))))))
            (->AtomMatch (int-array docs-out)
                         (.toArray starts-out)
                         (int-array freqs-out))))))))

(defn- docs->bitset
  ^BitSet [^ints docs]
  (let [bs (BitSet.)]
    (dotimes [i (alength docs)]
      (.set bs (aget docs i)))
    bs))

(defn evaluate
  "Evaluate query `tree` and return the matching documents as a `BitSet` of
  doc indexes. `matches` is a map from atom (term vector) to [[AtomMatch]]
  covering every atom in the tree. The empty tree (`nil`) matches nothing."
  ^BitSet [^long n matches tree]
  (letfn [(ev [t]
            (case (first t)
              :atom (docs->bitset (:docs (get matches (second t))))
              :not (let [^BitSet bs (ev (second t))]
                     (.flip bs 0 (int n))
                     bs)
              :and (let [[c & cs] (map ev (second t))]
                     (doseq [^BitSet o cs] (.and ^BitSet c o))
                     c)
              :or (let [[c & cs] (map ev (second t))]
                    (doseq [^BitSet o cs] (.or ^BitSet c o))
                    c)))]
    (if (nil? tree) (BitSet.) (ev tree))))
