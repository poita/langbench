(ns datalog.relation
  "Mutable relations: sets of tuples with incrementally maintained hash
  indexes.

  A tuple is a persistent vector of `Long` ranks (see [[datalog.constants]]).
  A relation keeps its tuples in insertion order in `rows`, a hash set for
  membership and duplicate elimination, and one hash index per access pattern
  (the vector of *bound* argument positions) that has been requested.

  Indexes are never rebuilt.  Each remembers how many rows it has absorbed and
  [[lookup]] feeds it the new rows on demand, so the total indexing work per
  index over a whole run is O(|relation|).

  Semi-naive evaluation needs to read a relation \"as it stood at the start of
  the round\" while the round appends to it.  A relation therefore has a
  *visible size*, set by [[freeze!]]: [[lookup]] and [[nth-row]] only expose the
  first `visible` rows, while [[add!]] and [[member?]] always see everything."
  (:import (java.util ArrayList HashMap HashSet)
           (clojure.lang IPersistentVector LazilyPersistentVector)))

(set! *warn-on-reflection* true)

(deftype Index [^HashMap buckets ^longs absorbed ^longs positions])

(deftype Relation [^ArrayList rows
                   ^HashSet members
                   ^HashMap indexes
                   ^longs visible])

(defn make-relation
  "A new empty relation."
  ^Relation []
  (Relation. (ArrayList.) (HashSet.) (HashMap.) (long-array 1)))

(defn size
  "Number of tuples in the relation (including not yet visible ones)."
  ^long [^Relation r]
  (.size ^ArrayList (.rows r)))

(defn add!
  "Adds `tuple`; returns true when it was not already present."
  [^Relation r tuple]
  (when (.add ^HashSet (.members r) tuple)
    (.add ^ArrayList (.rows r) tuple)
    true))

(defn member?
  "True when `tuple` is in the relation."
  [^Relation r tuple]
  (.contains ^HashSet (.members r) tuple))

(defn freeze!
  "Makes every tuple added so far visible to [[lookup]] and [[nth-row]]."
  [^Relation r]
  (aset ^longs (.visible r) 0 (size r)))

(defn visible-size
  "Number of rows visible to [[lookup]] and [[nth-row]]."
  ^long [^Relation r]
  (aget ^longs (.visible r) 0))

(defn nth-row
  "The `i`-th tuple in insertion order."
  [^Relation r ^long i]
  (.get ^ArrayList (.rows r) i))

(defn tuples
  "All tuples of the relation as a Clojure vector, in insertion order."
  [^Relation r]
  (vec (.rows r)))

(defn index-key
  "The index key of the tuple values at `positions` (a vector of ints): the
  bare `Long` when there is a single position, otherwise a vector."
  [tuple ^longs positions]
  (let [^IPersistentVector t tuple
        n (alength positions)]
    (if (== n 1)
      (.nth t (int (aget positions 0)))
      (let [a (object-array n)]
        (dotimes [i n] (aset a i (.nth t (int (aget positions i)))))
        (LazilyPersistentVector/createOwning a)))))

(defn index
  "Returns the index of `r` on the argument positions `positions` (a
  `long-array`, ascending), creating it when needed.  The result is a handle
  to pass to [[lookup]]; fetch it once and reuse it."
  ^Index [^Relation r ^longs positions]
  (let [pkey (vec positions)
        ^HashMap indexes (.indexes r)]
    (or (.get indexes pkey)
        (let [i (Index. (HashMap.) (long-array 1) positions)]
          (.put indexes pkey i)
          i))))

(defn lookup
  "Returns the `ArrayList` of visible tuples of `r` whose values at the
  positions of `idx` (from [[index]]) equal `key` (shaped as by
  [[index-key]]), or nil when there are none.  Rows that became visible since
  the last call are absorbed into the index first."
  ^ArrayList [^Relation r ^Index idx key]
  (let [^longs absorbed (.absorbed idx)
        ^HashMap buckets (.buckets idx)
        positions (.positions idx)
        vis (visible-size r)]
    (loop [i (aget absorbed 0)]
      (when (< i vis)
        (let [t (.get ^ArrayList (.rows r) (int i))
              k (index-key t positions)
              ^ArrayList b (or (.get buckets k)
                               (let [b (ArrayList. 2)] (.put buckets k b) b))]
          (.add b t)
          (recur (inc i)))))
    (aset absorbed 0 vis)
    (.get buckets key)))
