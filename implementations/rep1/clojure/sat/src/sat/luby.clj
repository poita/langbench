(ns sat.luby
  "The Luby sequence, used to schedule restarts.")

(defn luby
  "Returns the `i`th (0-based) element of the Luby sequence scaled by base `y`:
  `y^k` where k follows 0 0 1 0 0 1 2 0 0 1 0 0 1 2 3 ...  With y = 2 the
  sequence is 1 1 2 1 1 2 4 1 1 2 1 1 2 4 8 ..."
  ^double [^double y ^long i]
  (loop [size 1 seq 0]
    (if (< size (inc i))
      (recur (inc (* 2 size)) (inc seq))
      (loop [size size seq seq x i]
        (if (== (dec size) x)
          (Math/pow y seq)
          (let [size (bit-shift-right (dec size) 1)]
            (recur size (dec seq) (rem x size))))))))
