(ns ordered-map.core
  "A persistent ordered map from 64-bit integer keys to arbitrary values,
  implemented as a size-augmented AVL tree.

      (require '[ordered-map.core :as om])

      (def m (-> (om/ordered-map) (om/insert 10 \"a\") (om/insert 20 \"b\")))
      (om/floor m 15)      ;=> 10
      (om/rank m 20)       ;=> 1
      (om/select m 1)      ;=> 20
      (om/range-keys m 0 100) ;=> [10 20]

  Maps are immutable; every update returns a new map sharing structure with
  the old one. Insert, delete and all queries except `range-keys` and
  `entries` are O(log n); those two are O(log n + r) for r results.

  Keys must be integers that fit in a signed 64-bit `long`. The neighbour
  queries (`floor`, `ceil`, `succ`, `pred`) never compute `key ± 1`, so they
  are safe at `Long/MIN_VALUE` and `Long/MAX_VALUE`. Queries that look for a
  key return nil when there is none."
  (:refer-clojure :exclude [get contains? count min-key max-key])
  (:require [ordered-map.node :as n]
            [ordered-map.query :as q]
            [ordered-map.tree :as t])
  (:import (ordered_map.node Node)))

(set! *warn-on-reflection* true)

(declare ->OrderedMap insert)

(defn- node-key [^Node nd] (when nd (.-k nd)))

(defn- entries* [^Node root]
  (persistent!
   (q/reduce-all (fn [acc ^Node nd] (conj! acc (clojure.lang.MapEntry. (.-k nd) (.-v nd))))
                 (transient [])
                 root)))

(deftype OrderedMap [^Node root]
  clojure.lang.Counted
  (count [_] (n/size root))

  clojure.lang.Seqable
  (seq [_] (seq (entries* root)))

  clojure.lang.ILookup
  (valAt [this k] (.valAt this k nil))
  (valAt [_ k not-found]
    (if (integer? k)
      (if-let [^Node nd (q/find-node root (long k))] (.-v nd) not-found)
      not-found))

  clojure.lang.IFn
  (invoke [this k] (.valAt this k nil))
  (invoke [this k not-found] (.valAt this k not-found))

  Object
  (toString [this] (str "#ordered-map " (pr-str (into {} this)))))

(defmethod print-method OrderedMap [m ^java.io.Writer w]
  (.write w "#ordered-map ")
  (print-method (into [] (map (fn [[k v]] [k v])) (seq m)) w))

(defn ordered-map
  "Returns a new empty map, or one containing the entries of `kvs`, a
  collection of `[key value]` pairs."
  ([] (OrderedMap. nil))
  ([kvs] (reduce (fn [m [k v]] (insert m k v)) (ordered-map) kvs)))

(defn- root ^Node [^OrderedMap m] (.-root m))

(defn count
  "Number of entries in `m`. O(1)."
  ^long [m] (n/size (root m)))

(defn contains?
  "True if `m` has an entry for `k`."
  [m ^long k]
  (some? (q/find-node (root m) k)))

(defn get
  "The value stored under `k`, or `not-found` (default nil)."
  ([m k] (get m k nil))
  ([m ^long k not-found]
   (if-let [^Node nd (q/find-node (root m) k)] (.-v nd) not-found)))

(defn insert
  "Returns `m` with `k` mapped to `v`, replacing any existing value."
  [m ^long k v]
  (OrderedMap. (t/insert (root m) k v)))

(defn delete
  "Returns `m` without the entry for `k` (`m` itself if `k` is absent)."
  [m ^long k]
  (let [r (root m) r' (t/delete r k)]
    (if (identical? r r') m (OrderedMap. r'))))

(defn min-key "The smallest key, or nil if `m` is empty."
  [m] (node-key (q/min-node (root m))))

(defn max-key "The largest key, or nil if `m` is empty."
  [m] (node-key (q/max-node (root m))))

(defn floor "The largest key <= `k`, or nil."
  [m ^long k] (node-key (q/floor-node (root m) k)))

(defn ceil "The smallest key >= `k`, or nil."
  [m ^long k] (node-key (q/ceil-node (root m) k)))

(defn pred "The largest key strictly < `k`, or nil."
  [m ^long k] (node-key (q/lower-node (root m) k)))

(defn succ "The smallest key strictly > `k`, or nil."
  [m ^long k] (node-key (q/higher-node (root m) k)))

(defn rank
  "The number of keys strictly less than `k`; `k` need not be present."
  ^long [m ^long k] (q/rank (root m) k))

(defn select
  "The `i`-th smallest key (0-based), or nil if `i` >= (count m)."
  [m ^long i] (node-key (q/select-node (root m) i)))

(defn reduce-keys
  "Reduces `f` as `(f acc key)` over the keys in [lo, hi] in ascending order.
  Supports `reduced`. O(log n + r)."
  [f init m lo hi]
  (q/reduce-range (fn [acc ^Node nd] (f acc (.-k nd))) init (root m) lo hi))

(defn range-keys
  "A vector of the keys x with lo <= x <= hi in ascending order (empty if
  there are none or lo > hi). O(log n + r)."
  [m lo hi]
  (persistent! (reduce-keys conj! (transient []) m lo hi)))

(defn entries
  "A vector of all `[key value]` entries in ascending key order."
  [m] (entries* (root m)))
