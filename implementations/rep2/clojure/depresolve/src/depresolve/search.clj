(ns depresolve.search
  "The specified depth-first, newest-first, chronologically backtracking
  search, run over a compiled `depresolve.index/Index` with an explicit
  stack (no recursion, so depth is bounded only by the heap).

  State:

  * `pending` -- the pending requirements, a singly linked list of `Node`s.
    Choosing a version pushes its requirements in front of the rest; the
    tail is shared, never copied, between choice points.
  * `chosen`  -- an `int[]` mapping package id to the index of its chosen
    version in the newest-first order (-1: none).
  * a choice-point stack (parallel arrays) with one entry per chosen
    package: the package, the next untried candidate index, the end of its
    candidate range and the pending list that follows the requirement that
    created it.  The stack doubles as the trail: popping a choice point
    un-chooses its package, so nothing is ever copied on backtracking."
  (:require [depresolve.index :as index])
  (:import (depresolve.index Index Req)))

(set! *warn-on-reflection* true)

(deftype Node [^Req req next])

(defn- push-reqs
  "Returns `rest` with the requirements `reqs` (an `Object[]` of `Req`) pushed
  in front, preserving their order."
  [^objects reqs rest]
  (loop [i (dec (alength reqs)) node rest]
    (if (neg? i)
      node
      (recur (dec i) (Node. (aget reqs i) node)))))

(defn search
  "Runs the search over `idx`.  Returns the `int[]` of chosen version
  indices, one per package id (-1 for packages not chosen), or `nil` when no
  resolution exists."
  [^Index idx]
  (let [versions (.versions idx)
        reqs     (.reqs idx)
        n        (alength ^objects (.names idx))
        chosen   (int-array n -1)
        cp-pkg   (int-array (inc n))
        cp-next  (int-array (inc n))
        cp-to    (int-array (inc n))
        cp-rest  (object-array (inc n))
        root     (push-reqs (.root idx) nil)]
    ;; `pending` is a Node, nil (success) or ::fail.
    (loop [pending root, sp 0]
      (cond
        (nil? pending) chosen

        (identical? pending ::fail)
        ;; Backtrack: pop exhausted choice points, retry the newest one that
        ;; still has an untried candidate.
        (let [top (long (loop [s sp]
                    (cond
                      (zero? s) -1
                      (< (aget cp-next (dec s)) (aget cp-to (dec s))) s
                      :else (do (aset chosen (aget cp-pkg (dec s)) -1)
                                (recur (dec s))))))]
          (if (neg? top)
            nil
            (let [k    (dec top)
                  pkg  (aget cp-pkg k)
                  ci   (aget cp-next k)]
              (aset cp-next k (unchecked-inc-int ci))
              (aset chosen pkg ci)
              (recur (push-reqs (aget ^objects (aget ^objects reqs pkg) ci)
                                (aget cp-rest k))
                     top))))

        :else
        (let [^Node node pending
              ^Req r     (.req node)
              rest       (.next node)
              pkg        (.pkg r)
              c          (aget chosen pkg)]
          (if (neg? c)
            (let [from (.from r)]
              (if (< from (.to r))
                (do (aset cp-pkg sp pkg)
                    (aset cp-next sp (unchecked-inc-int from))
                    (aset cp-to sp (.to r))
                    (aset cp-rest sp rest)
                    (aset chosen pkg from)
                    (recur (push-reqs (aget ^objects (aget ^objects reqs pkg) from) rest)
                           (unchecked-inc sp)))
                (recur ::fail sp)))
            (if (and (<= (.from r) c) (< c (.to r)))
              (recur rest sp)
              (recur ::fail sp))))))))
