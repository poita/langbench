(ns datalog.join
  "The join executor: runs a compiled rule against the relations.

  A rule is compiled (by `datalog.plan`) into an `Executor` holding an array
  of `Step`s, one per positive body atom, in join order, an array of
  `filters` to apply at each step, and a head template. Running it is an
  indexed nested-loop join: each step either enumerates the matching rows of its
  relation, binding variable slots in a shared `int[]`, or (when every
  argument is already bound) just tests membership. Negated atoms and
  comparisons are `filters` attached to the first step after which all
  their variables are bound.

  *Specs.* Terms are encoded as one `long`: a constant is its interned id
  (>= 0), a variable is `-(slot+1)`."
  (:require [datalog.storage :as st])
  (:import (datalog.storage IIndex IRelation)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(defn spec-val
  "The value of a term spec under the bindings `b`."
  ^long [^ints b ^long spec]
  (if (>= spec 0) spec (long (aget b (- -1 spec)))))

;; ---------------------------------------------------------------------------
;; Filters

(definterface IFilter
  (^boolean test [^ints b]))

(deftype NegFilter [^IRelation rel ^ints specs ^ints scratch]
  IFilter
  (test [_ b]
    (dotimes [i (alength specs)]
      (aset scratch i (int (spec-val b (aget specs i)))))
    (not (.has rel scratch))))

(def cmp-ops
  "Comparison operators in the order used by `CmpFilter`."
  [:< :<= :> :>= := :!=])

(deftype CmpFilter [^long op ^long left ^long right]
  IFilter
  (test [_ b]
    ;; Ids are ranks in the global constant order, so comparing ids compares
    ;; constants.
    (let [x (spec-val b left) y (spec-val b right)]
      (case op
        0 (< x y)
        1 (<= x y)
        2 (> x y)
        3 (>= x y)
        4 (== x y)
        5 (not= x y)))))

(defn- passes? [^objects fs ^ints b]
  (let [n (alength fs)]
    (loop [i 0]
      (cond (== i n) true
            (.test ^IFilter (aget fs i) b) (recur (inc i))
            :else false))))

;; ---------------------------------------------------------------------------
;; Steps

(def mode-scan
  "Enumerate all committed rows."
  0)
(def mode-delta
  "Enumerate the rows of the relation's latest delta."
  1)
(def mode-index
  "Enumerate the rows matching a key through a secondary index."
  2)
(def mode-exists
  "Every argument is bound: test membership only."
  3)

(deftype Step [^long mode
               ^IRelation rel
               ^IIndex idx          ; mode-index / mode-exists
               ^ints kspec          ; key specs in index column order
               ^ints key            ; scratch for the key
               ^ints bcols          ; columns that bind a fresh variable...
               ^ints bslots         ; ...and the slots they bind
               ^ints ccols          ; columns that must equal a bound value...
               ^ints cspecs         ; ...given by these specs
               ^objects filters])

(defn- fill-key! [^Step s ^ints b]
  (let [^ints ks (.-kspec s) ^ints key (.-key s)]
    (dotimes [i (alength ks)]
      (aset key i (int (spec-val b (aget ks i)))))))

(defn- bind-row! [^Step s ^ints data ^long base ^ints b]
  (let [^ints bc (.-bcols s) ^ints bs (.-bslots s)]
    (dotimes [k (alength bc)]
      (aset b (aget bs k) (aget data (+ base (aget bc k)))))))

(defn- checks-pass? [^Step s ^ints data ^long base ^ints b]
  (let [^ints cc (.-ccols s) ^ints cs (.-cspecs s) n (alength cc)]
    (loop [k 0]
      (cond (== k n) true
            (== (aget data (+ base (aget cc k))) (spec-val b (aget cs k))) (recur (inc k))
            :else false))))

;; ---------------------------------------------------------------------------
;; Executor

(definterface IExecutor
  (run [^long i])
  (visit [^ints data ^long id ^long i]))

(deftype Executor [^objects steps
                   ^ints b            ; variable bindings
                   ^objects pre       ; filters that need no variables
                   ^ints hspecs       ; head template
                   ^ints out          ; scratch for the head tuple
                   ^IRelation head]
  IExecutor
  (run [this i]
    (if (== i (alength steps))
      (do (dotimes [k (alength hspecs)]
            (aset out k (int (spec-val b (aget hspecs k)))))
          (.add head out)
          nil)
      (let [^Step s (aget steps i)
            ^IRelation rel (.-rel s)]
        (case (.-mode s)
          0 (let [data (.data rel) hi (.visible rel)]
              (loop [id 0]
                (when (< id hi)
                  (.visit this data id i)
                  (recur (inc id)))))
          1 (let [data (.data rel) hi (.deltaHi rel)]
              (loop [id (.deltaLo rel)]
                (when (< id hi)
                  (.visit this data id i)
                  (recur (inc id)))))
          2 (let [^IIndex idx (.-idx s) data (.data rel)]
              (fill-key! s b)
              (loop [id (.lookup idx data ^ints (.-key s))]
                (when (>= id 0)
                  (.visit this data id i)
                  (recur (.chainNext idx id)))))
          3 (do (fill-key! s b)
                (when (>= (.lookup ^IIndex (.-idx s) (.data rel) ^ints (.-key s)) 0)
                  (when (passes? ^objects (.-filters s) b)
                    (.run this (inc i)))))))))

  (visit [this data id i]
    (let [^Step s (aget steps i)
          base (* id (.arity ^IRelation (.-rel s)))]
      (bind-row! s data base b)
      (when (and (checks-pass? s data base b)
                 (passes? ^objects (.-filters s) b))
        (.run this (inc i))))))

(defn execute!
  "Runs the compiled rule once, adding every derived head tuple to its
  relation (they become visible at the next `commit`)."
  [^Executor ex]
  (when (passes? ^objects (.-pre ex) ^ints (.-b ex))
    (.run ex 0))
  nil)
