(ns sat.luby
  "The Luby restart sequence 1 1 2 1 1 2 4 1 1 2 1 1 2 4 8 ...")

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(defn luby
  "Returns the `i`-th (0-based) element of the Luby sequence scaled by base `y`,
  i.e. `y^k` where k follows the exponent sequence 0 0 1 0 0 1 2 0 0 1 ...
  `y` and `i` must be integers, `y >= 1` and `i >= 0`."
  ^long [^long y ^long i]
  (let [[size seq-exp] (loop [size 1 e 0]
                         (if (< size (inc i))
                           (recur (inc (* 2 size)) (inc e))
                           [size e]))]
    (loop [size (long size) e (long seq-exp) x i]
      (if (== (dec size) x)
        (loop [r 1 k e] (if (zero? k) r (recur (* r y) (dec k))))
        (let [size (bit-shift-right (dec size) 1)]
          (recur size (dec e) (rem x size)))))))
