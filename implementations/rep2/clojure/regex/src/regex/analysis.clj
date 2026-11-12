(ns regex.analysis
  "Static analysis of syntax trees, used to skip hopeless start positions
  and to avoid the empty-iteration check where it cannot matter."
  (:require [regex.charset :as cs]))

(defn nullable?
  "Conservatively true when `node` might match the empty string (anchors are
  assumed to succeed)."
  [node]
  (case (node 0)
    (:char :any :set) false
    (:bol :eol) true
    :seq (every? nullable? (node 1))
    :alt (boolean (some nullable? (node 1)))
    :group (nullable? (node 2))
    :rep (or (zero? (node 2)) (nullable? (node 1)))))

(defn first-set
  "A new charset (see regex.charset) of every character that may begin a
  non-empty match of `node`."
  ^booleans [node]
  (case (node 0)
    :char (cs/add-char! (cs/empty-set) (node 1))
    :any (cs/negate (cs/empty-set))
    :set (cs/union! (cs/empty-set) (node 1))
    (:bol :eol) (cs/empty-set)
    :seq (let [acc (cs/empty-set)]
           (loop [xs (node 1)]
             (when-let [x (first xs)]
               (cs/union! acc (first-set x))
               (when (nullable? x) (recur (next xs)))))
           acc)
    :alt (reduce (fn [acc x] (cs/union! acc (first-set x))) (cs/empty-set) (node 1))
    :group (first-set (node 2))
    :rep (if (= 0 (node 3)) (cs/empty-set) (first-set (node 1)))))

(defn start-anchored?
  "True when `node` can only match starting at position 0."
  [node]
  (case (node 0)
    :bol true
    (:char :any :set :eol) false
    :seq (boolean (some start-anchored? (node 1)))
    :alt (every? start-anchored? (node 1))
    :group (start-anchored? (node 2))
    :rep (and (pos? (node 2)) (start-anchored? (node 1)))))
