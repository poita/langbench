(ns chess-perft.property-test
  "Property-based tests over positions reached by random legal play."
  (:require [chess-perft.core :as chess]
            [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]))

(def gen-position
  "Positions reached from the start by up to 60 random legal plies. The
  generator draws a list of numbers used to pick moves."
  (gen/fmap
   (fn [picks]
     (reduce (fn [pos pick]
               (let [moves (chess/legal-moves pos)]
                 (if (empty? moves)
                   (reduced pos)
                   (chess/make-move pos (nth moves (mod pick (count moves)))))))
             (chess/start-position)
             picks))
   (gen/vector gen/nat 0 60)))

(defspec perft-is-sum-over-children 50
  (prop/for-all [pos gen-position]
    (= (chess/perft pos 2)
       (reduce + (map #(chess/perft (chess/make-move pos %) 1) (chess/legal-moves pos))))))

(defspec divide-totals-perft 50
  (prop/for-all [pos gen-position]
    (let [rows (chess/divide pos 2)]
      (and (= (chess/perft pos 2) (reduce + (map second rows)))
           (= (map first rows) (sort (map first rows)))))))

(defspec bulk-count-matches-generation 100
  (prop/for-all [pos gen-position]
    (= (chess/count-legal-moves pos) (count (chess/legal-moves pos)) (chess/perft pos 1))))

(defspec fen-round-trip 100
  (prop/for-all [pos gen-position]
    (let [fen (chess/to-fen pos)]
      (= fen (chess/to-fen (chess/parse-fen fen))))))

(defspec moves-are-unique-uci 100
  (prop/for-all [pos gen-position]
    (let [ucis (map chess/move->uci (chess/legal-moves pos))]
      (= (count ucis) (count (set ucis))))))

(defspec legal-moves-never-leave-king-attacked 100
  ;; the side that just moved must have its king safe: playing any move and
  ;; asking the generator again must never allow capturing the king
  (prop/for-all [pos gen-position]
    (every? (fn [mv]
              (let [after (chess/make-move pos mv)]
                (every? (fn [reply]
                          (let [fen (chess/to-fen (chess/make-move after reply))]
                            (= 2 (count (re-seq #"[Kk]" (first (str/split fen #" ")))))))
                        (chess/legal-moves after))))
            (chess/legal-moves pos))))
