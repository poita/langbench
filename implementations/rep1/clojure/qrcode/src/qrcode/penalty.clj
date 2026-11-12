(ns qrcode.penalty
  "Mask penalty scoring (rules N1..N4) used by automatic mask selection."
  (:require [qrcode.matrix])
  (:import (qrcode.matrix Grid)))

(set! *warn-on-reflection* true)

(def ^:private ^:const finder-like-a 2r10111010000) ; #.###.#....
(def ^:private ^:const finder-like-b 2r00001011101) ; ....#.###.#

(defn- run-score
  "N1 contribution of a finished run of `len` same-coloured modules."
  ^long [^long len]
  (if (>= len 5) (+ 3 (- len 5)) 0))

(defn- line-penalty
  "N1 (runs) plus N3 (finder-like patterns) for the line of `n` modules
  starting at index `start` and advancing by `step`."
  ^long [^bytes modules ^long n ^long start ^long step]
  (loop [k 0, i start, run 0, prev -1, window 0, score 0]
    (if (== k n)
      (+ score (run-score run))
      (let [c (long (aget modules i))
            same? (== c prev)
            score (if same? score (+ score (run-score run)))
            run (if same? (inc run) 1)
            window (bit-and (bit-or (bit-shift-left window 1) c) 0x7FF)
            score (if (and (>= k 10)
                           (or (== window finder-like-a) (== window finder-like-b)))
                    (+ score 40)
                    score)]
        (recur (inc k) (+ i step) run c window score)))))

(defn- block-penalty
  "N2: 3 for every 2x2 block of one colour."
  ^long [^bytes modules ^long n]
  (loop [y 0, score 0]
    (if (== y (dec n))
      score
      (recur (inc y)
             (long
              (loop [x 0, score score]
               (if (== x (dec n))
                 score
                 (let [i (+ (* y n) x)
                       c (aget modules i)]
                   (recur (inc x)
                          (if (and (== c (aget modules (inc i)))
                                   (== c (aget modules (+ i n)))
                                   (== c (aget modules (+ i n 1))))
                            (+ score 3)
                            score))))))))))

(defn- balance-penalty
  "N4: 10 per complete 5% step of deviation of the dark share from 50%."
  ^long [^bytes modules ^long n]
  (let [total (* n n)
        dark (loop [i 0, d 0]
               (if (== i total) d (recur (inc i) (+ d (aget modules i)))))]
    (* 10 (quot (abs (- (* 20 dark) (* 10 total))) total))))

(defn penalty
  "Total penalty score of the complete symbol in `g`."
  ^long [^Grid g]
  (let [n (.-size g)
        modules ^bytes (.-modules g)
        lines (loop [i 0, score 0]
                (if (== i n)
                  score
                  (recur (inc i)
                         (+ score
                            (line-penalty modules n (* i n) 1)
                            (line-penalty modules n i n)))))]
    (+ lines (block-penalty modules n) (balance-penalty modules n))))
