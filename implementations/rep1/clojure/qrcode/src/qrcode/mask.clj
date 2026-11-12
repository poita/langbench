(ns qrcode.mask
  "The eight data mask patterns."
  (:require [qrcode.matrix :as matrix])
  (:import (qrcode.matrix Grid)))

(set! *warn-on-reflection* true)

(defn- inverts?
  "Whether mask `m` inverts module (x, y)."
  [^long m ^long x ^long y]
  (case m
    0 (even? (+ x y))
    1 (even? y)
    2 (zero? (mod x 3))
    3 (zero? (mod (+ x y) 3))
    4 (even? (+ (quot x 3) (quot y 2)))
    5 (let [p (* x y)] (zero? (+ (mod p 2) (mod p 3))))
    6 (let [p (* x y)] (even? (+ (mod p 2) (mod p 3))))
    7 (even? (+ (mod (+ x y) 2) (mod (* x y) 3)))))

(defn apply-mask!
  "Inverts, in place, every non-function module of `g` selected by mask `m`
  (0..7). Applying the same mask twice restores the grid. Returns `g`."
  [^Grid g ^long m]
  (let [n (.-size g)
        modules ^bytes (.-modules g)
        function ^booleans (.-function g)]
    (dotimes [y n]
      (dotimes [x n]
        (let [i (+ (* y n) x)]
          (when (and (not (aget function i)) (inverts? m x y))
            (aset modules i (byte (bit-xor 1 (aget modules i))))))))
    g))
