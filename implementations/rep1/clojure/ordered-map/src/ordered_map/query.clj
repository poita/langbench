(ns ordered-map.query
  "Read-only queries on AVL trees of `ordered-map.node/Node`. Point queries
  are a single root-to-leaf descent (O(log n)); rank and select use the
  subtree sizes; range traversal is O(log n + r).

  Functions returning a node return `nil` when there is none."
  (:require [ordered-map.node :as n])
  (:import (ordered_map.node Node)))

(set! *warn-on-reflection* true)

(defn find-node
  "The node holding exactly key `k`, or nil."
  ^Node [^Node t ^long k]
  (loop [t t]
    (when-not (nil? t)
      (let [tk (.-k t)]
        (cond (< k tk) (recur (.-left t))
              (> k tk) (recur (.-right t))
              :else t)))))

(defn min-node ^Node [^Node t]
  (when-not (nil? t)
    (loop [t t]
      (let [l (.-left t)] (if (nil? l) t (recur l))))))

(defn max-node ^Node [^Node t]
  (when-not (nil? t)
    (loop [t t]
      (let [r (.-right t)] (if (nil? r) t (recur r))))))

(defn floor-node
  "The node with the largest key <= `k`."
  ^Node [^Node t ^long k]
  (loop [t t best nil]
    (if (nil? t)
      best
      (let [tk (.-k t)]
        (cond (< k tk) (recur (.-left t) best)
              (> k tk) (recur (.-right t) t)
              :else t)))))

(defn ceil-node
  "The node with the smallest key >= `k`."
  ^Node [^Node t ^long k]
  (loop [t t best nil]
    (if (nil? t)
      best
      (let [tk (.-k t)]
        (cond (> k tk) (recur (.-right t) best)
              (< k tk) (recur (.-left t) t)
              :else t)))))

(defn lower-node
  "The node with the largest key strictly < `k`."
  ^Node [^Node t ^long k]
  (loop [t t best nil]
    (if (nil? t)
      best
      (if (> k (.-k t))
        (recur (.-right t) t)
        (recur (.-left t) best)))))

(defn higher-node
  "The node with the smallest key strictly > `k`."
  ^Node [^Node t ^long k]
  (loop [t t best nil]
    (if (nil? t)
      best
      (if (< k (.-k t))
        (recur (.-left t) t)
        (recur (.-right t) best)))))

(defn rank
  "Number of keys strictly less than `k`."
  ^long [^Node t ^long k]
  (loop [t t acc 0]
    (if (nil? t)
      acc
      (let [tk (.-k t)]
        (if (> k tk)
          (recur (.-right t) (+ acc 1 (n/size (.-left t))))
          (recur (.-left t) acc))))))

(defn select-node
  "The node with the `i`-th smallest key (0-based), or nil if `i` is out of
  range."
  ^Node [^Node t ^long i]
  (when (and (>= i 0) (< i (n/size t)))
    (loop [t t i i]
      (let [ls (n/size (.-left t))]
        (cond (< i ls) (recur (.-left t) i)
              (> i ls) (recur (.-right t) (- i ls 1))
              :else t)))))

(defn reduce-range
  "Reduces `f` over the nodes with lo <= key <= hi in ascending key order, as
  `(f acc node)`, honouring `reduced`. Only the subtrees that can intersect
  the interval are visited."
  [f init ^Node t lo hi]
  (let [lo (long lo) hi (long hi)]
   (letfn [(walk [^Node t acc]
            (if (or (nil? t) (reduced? acc))
              acc
              (let [tk (.-k t)
                    acc (if (< lo tk) (walk (.-left t) acc) acc)]
                (if (reduced? acc)
                  acc
                  (let [acc (if (and (<= lo tk) (<= tk hi)) (f acc t) acc)]
                    (if (and (< tk hi) (not (reduced? acc)))
                      (walk (.-right t) acc)
                      acc))))))]
    (unreduced (walk t init)))))

(defn reduce-all
  "Reduces `f` over every node in ascending key order, as `(f acc node)`."
  [f init ^Node t]
  (reduce-range f init t Long/MIN_VALUE Long/MAX_VALUE))
