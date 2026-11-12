(ns qrcode.reedsolomon
  "Reed-Solomon error correction over GF(2^8) with the QR Code primitive
  polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D).")

(set! *warn-on-reflection* true)

(def ^:private ^"[I" exp-table
  ;; Doubled in length so that products need no modular reduction.
  (let [t (int-array 510)]
    (loop [i 0, x 1]
      (when (< i 510)
        (aset t i x)
        (recur (inc i)
               (let [x2 (bit-shift-left x 1)]
                 (if (>= x2 256) (bit-xor x2 0x11D) x2)))))
    t))

(def ^:private ^"[I" log-table
  (let [t (int-array 256)]
    (dotimes [i 255]
      (aset t (aget exp-table i) i))
    t))

(defn multiply
  "Product of two field elements (integers 0..255)."
  ^long [^long a ^long b]
  (if (or (zero? a) (zero? b))
    0
    (aget exp-table (+ (aget log-table a) (aget log-table b)))))

(defn generator
  "Coefficients of the degree-`degree` generator polynomial
  prod_{i<degree} (x - 2^i), highest degree first, omitting the leading 1.
  Returns an int array of length `degree`."
  ^ints [^long degree]
  (let [coeffs (int-array degree)]
    (aset coeffs (dec degree) 1)
    (loop [i 0, root 1]
      (when (< i degree)
        (dotimes [j degree]
          (aset coeffs j (multiply (aget coeffs j) root))
          (when (< (inc j) degree)
            (aset coeffs j (bit-xor (aget coeffs j) (aget coeffs (inc j))))))
        (recur (inc i) (multiply root 2))))
    coeffs))

(def ^:private generator-cache (atom {}))

(defn- cached-generator ^ints [^long degree]
  (or (get @generator-cache degree)
      (let [g (generator degree)]
        (swap! generator-cache assoc degree g)
        g)))

(defn remainder
  "Remainder of data(x) * x^degree divided by the generator polynomial:
  the `degree` ECC codewords for the int array `data` (highest degree first)."
  ^ints [^ints data ^long degree]
  (let [^ints gen (cached-generator degree)
        result (int-array degree)
        last-idx (dec degree)]
    (dotimes [i (alength data)]
      (let [factor (bit-xor (aget data i) (aget result 0))]
        (System/arraycopy result 1 result 0 last-idx)
        (aset result last-idx 0)
        (when-not (zero? factor)
          (dotimes [j degree]
            (aset result j (bit-xor (aget result j)
                                    (multiply (aget gen j) factor)))))))
    result))
