(ns chess-perft.perft
  "Perft and divide on top of the legal move generator.

  The search walks the whole game tree depth first. At depth 1 it does not
  play the moves: the number of legal moves *is* the number of leaves (bulk
  counting)."
  (:require [chess-perft.move :as m]
            [chess-perft.movegen :as mg]))

(set! *warn-on-reflection* true)

(defn- search
  "Leaf count of the tree below `pos`, `depth` >= 1 plies deep."
  ^long [pos ^long depth]
  (if (== depth 1)
    (mg/count-legal-moves pos)
    (let [ml (m/new-movelist)
          _  (mg/generate! pos ml)
          n  (aget ^ints ml 0)]
      (loop [i 1 total 0]
        (if (<= i n)
          (recur (inc i)
                 (+ total (search (m/make-move pos (aget ^ints ml i)) (dec depth))))
          total)))))

(defn perft
  "Number of leaf nodes reached by playing every sequence of `depth` legal
  moves from `pos`. `(perft pos 0)` is 1."
  ^long [pos ^long depth]
  (if (<= depth 0) 1 (search pos depth)))

(defn divide
  "For each legal move of `pos`, the perft of the position after it at
  `depth - 1`. Returns a vector of `[uci-string count]` pairs sorted by the
  move string; `depth` must be at least 1."
  [pos ^long depth]
  {:pre [(>= depth 1)]}
  (->> (mg/legal-moves pos)
       (mapv (fn [mv] [(m/move->uci mv) (perft (m/make-move pos mv) (dec depth))]))
       (sort-by first)
       vec))
