(ns datalog.storage
  "Tuple storage for the evaluator: relations and their hash indexes.

  Constants are interned to dense `int` ids elsewhere, so a tuple is a row of
  ints. A `Relation` keeps its rows back to back in one growing `int[]`; a
  row's position is its *tuple id*. Rows are only ever appended.

  Visibility. `add` appends a row at once (and deduplicates it through the
  relation's *primary* index, a hash set over whole rows), but secondary
  indexes and scans only see rows after `commit`. `commit` also records the
  *delta*, the ids appended since the previous commit, which is what
  semi-naive evaluation joins against. Every secondary index is therefore
  updated exactly once per row over a whole run.

  An index maps the values of some columns to a chain of tuple ids: an
  open-addressing table holds one head id per distinct key and `nxt` links the
  ids sharing that key."
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

;; ---------------------------------------------------------------------------
;; Hashing

(def ^:private ^:const golden -7046029254386353131)

(defn- mix ^long [^long h ^long v]
  (unchecked-multiply (bit-xor h v) golden))

(defn- finish ^long [^long h]
  (bit-xor h (unsigned-bit-shift-right h 32)))

(defn- hash-row
  "Hash of the values of columns `cols` in the row starting at `base`."
  ^long [^ints data ^long base ^ints cols]
  (let [n (alength cols)]
    (loop [i 0 h 0]
      (if (< i n)
        (recur (inc i) (mix h (aget data (+ base (aget cols i)))))
        (finish h)))))

(defn- hash-key
  "Hash of a key array; equals `hash-row` of any row whose `cols` values
  are the key."
  ^long [^ints key]
  (let [n (alength key)]
    (loop [i 0 h 0]
      (if (< i n)
        (recur (inc i) (mix h (aget key i)))
        (finish h)))))

(defn- same-row?
  "Do the rows at `a` and `b` agree on `cols`?"
  [^ints data ^long a ^long b ^ints cols]
  (let [n (alength cols)]
    (loop [i 0]
      (cond (== i n) true
            (let [c (aget cols i)] (== (aget data (+ a c)) (aget data (+ b c)))) (recur (inc i))
            :else false))))

(defn- same-key?
  "Does the row at `base` have the values `key` on `cols`?"
  [^ints data ^long base ^ints cols ^ints key]
  (let [n (alength cols)]
    (loop [i 0]
      (cond (== i n) true
            (== (aget data (+ base (aget cols i))) (aget key i)) (recur (inc i))
            :else false))))

;; ---------------------------------------------------------------------------
;; Index

(definterface IIndex
  (^boolean insertUnique [^ints data ^long id])
  (insert [^ints data ^long id])
  (^long lookup [^ints data ^ints key])
  (^long chainNext [^long id])
  (rehash [^ints data]))

(deftype Index [^ints cols ^long arity
                ^:unsynchronized-mutable ^ints heads
                ^:unsynchronized-mutable ^ints nxt
                ^:unsynchronized-mutable ^long nkeys]
  IIndex
  (insertUnique [this data id]
    ;; Insert row `id` unless an equal row is present. Whole-row indexes only.
    (let [base (* id arity)
          mask (dec (alength heads))]
      (loop [slot (bit-and (hash-row data base cols) mask)]
        (let [head (aget heads slot)]
          (cond
            (== head -1) (do (aset heads slot (int id))
                             (set! nkeys (inc nkeys))
                             (when (> (* 2 nkeys) (alength heads)) (.rehash this data))
                             true)
            (same-row? data (* head arity) base cols) false
            :else (recur (bit-and (inc slot) mask)))))))

  (insert [this data id]
    (when (>= id (alength nxt))
      (set! nxt (Arrays/copyOf nxt (int (max 16 (* 2 (alength nxt)) (inc id))))))
    (let [base (* id arity)
          mask (dec (alength heads))]
      (loop [slot (bit-and (hash-row data base cols) mask)]
        (let [head (aget heads slot)]
          (cond
            (== head -1) (do (aset heads slot (int id))
                             (aset nxt id (int -1))
                             (set! nkeys (inc nkeys))
                             (when (> (* 2 nkeys) (alength heads)) (.rehash this data)))
            (same-row? data (* head arity) base cols) (do (aset nxt id head)
                                                          (aset heads slot (int id)))
            :else (recur (bit-and (inc slot) mask)))))))

  (lookup [this data key]
    (let [mask (dec (alength heads))]
      (loop [slot (bit-and (hash-key key) mask)]
        (let [head (aget heads slot)]
          (cond
            (== head -1) -1
            (same-key? data (* head arity) cols key) (long head)
            :else (recur (bit-and (inc slot) mask)))))))

  (chainNext [this id] (long (aget nxt id)))

  (rehash [this data]
    (let [old heads
          nh (int-array (* 2 (alength old)) -1)
          mask (dec (alength nh))]
      (dotimes [i (alength old)]
        (let [h (aget old i)]
          (when-not (== h -1)
            (loop [slot (bit-and (hash-row data (* h arity) cols) mask)]
              (if (== (aget nh slot) -1)
                (aset nh slot h)
                (recur (bit-and (inc slot) mask)))))))
      (set! heads nh))))

(defn- make-index ^datalog.storage.IIndex [^ints cols arity]
  (->Index cols arity (int-array 16 -1) (int-array 16) 0))

;; ---------------------------------------------------------------------------
;; Relation

(definterface IRelation
  (^long arity [])
  (^ints data [])
  (^long size [])
  (^long visible [])
  (^long deltaLo [])
  (^long deltaHi [])
  (^boolean add [^ints tuple])
  (^boolean has [^ints tuple])
  (commit [])
  (primary [])
  (indexOn [^ints cols]))

(deftype Relation [^long arity
                   ^:unsynchronized-mutable ^ints data
                   ^:unsynchronized-mutable ^long n
                   ^:unsynchronized-mutable ^long vis
                   ^:unsynchronized-mutable ^long dlo
                   ^:unsynchronized-mutable ^long dhi
                   ^IIndex prim
                   ^:unsynchronized-mutable indexes]
  IRelation
  (arity [_] arity)
  (data [_] data)
  (size [_] n)
  (visible [_] vis)
  (deltaLo [_] dlo)
  (deltaHi [_] dhi)

  (add [this tuple]
    (let [base (* n arity)]
      (when (> (+ base arity) (alength data))
        (set! data (Arrays/copyOf data (int (* 2 (alength data))))))
      (System/arraycopy tuple 0 data base arity)
      (if (.insertUnique prim data n)
        (do (set! n (inc n)) true)
        false)))

  (has [_ tuple]
    (>= (.lookup prim data tuple) 0))

  (commit [_]
    (let [lo vis hi n d data]
      (doseq [^IIndex ix (vals indexes)]
        (loop [id lo]
          (when (< id hi)
            (.insert ix d id)
            (recur (inc id)))))
      (set! dlo lo)
      (set! dhi hi)
      (set! vis hi)))

  (primary [_] prim)

  (indexOn [_ cols]
    (let [k (vec cols)]
      (or (get indexes k)
          (let [ix (make-index cols arity)
                d data
                hi vis]
            (loop [id 0]
              (when (< id hi)
                (.insert ix d id)
                (recur (inc id))))
            (set! indexes (assoc indexes k ix))
            ix)))))

(defn make-relation
  "A new empty relation of the given arity."
  ^datalog.storage.IRelation [^long arity]
  (->Relation arity (int-array (* 16 arity)) 0 0 0 0
              (make-index (int-array (range arity)) arity)
              {}))

(defn row
  "The row with tuple id `id` as a vector of ints."
  [^IRelation rel ^long id]
  (let [d (.data rel) a (.arity rel) base (* id a)]
    (mapv #(aget d (+ base (long %))) (range a))))
