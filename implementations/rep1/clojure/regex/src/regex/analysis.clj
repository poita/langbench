(ns regex.analysis
  "Static analysis of syntax trees used to prune the search for a match start:
  the set of characters a match can begin with, and whether a pattern can only
  match at position 0."
  (:require [regex.charset :as cs]))

(defn first-info
  "Returns `{:set bools, :nullable? bool}` for `node`: `:set` holds every
  character a non-empty match of the node can start with, and `:nullable?` is
  true when the node might match without consuming a character. Anchors are
  treated as nullable, so the result is always conservative."
  [node]
  (case (first node)
    :char {:set (cs/singleton (second node)) :nullable? false}
    :any {:set (cs/full) :nullable? false}
    :set {:set (second node) :nullable? false}
    (:bol :eol) {:set (cs/empty-set) :nullable? true}
    :group (first-info (nth node 2))
    :seq (loop [[n & more :as items] (second node)
                acc (cs/empty-set)]
           (if (empty? items)
             {:set acc :nullable? true}
             (let [{:keys [set nullable?]} (first-info n)]
               (cs/union! acc set)
               (if nullable?
                 (recur more acc)
                 {:set acc :nullable? false}))))
    :alt (let [acc (cs/empty-set)
               infos (map first-info (second node))]
           (doseq [{:keys [set]} infos] (cs/union! acc set))
           {:set acc :nullable? (boolean (some :nullable? infos))})
    :rep (let [[_ x lo hi] node
               {:keys [set nullable?]} (first-info x)]
           (if (and hi (zero? hi))
             {:set (cs/empty-set) :nullable? true}
             {:set set :nullable? (or nullable? (zero? lo))}))))

(defn anchored-start?
  "True when every match of `node` must begin with a `^` assertion, so only
  start position 0 can succeed."
  [node]
  (case (first node)
    :bol true
    :group (anchored-start? (nth node 2))
    :seq (let [items (second node)]
           (boolean (and (seq items) (anchored-start? (first items)))))
    :alt (every? anchored-start? (second node))
    :rep (let [[_ x lo hi] node]
           (and (pos? lo) (anchored-start? x)))
    false))
