(ns qrcode.bits
  "A fixed-capacity, append-only bit buffer backed by an array of codewords.
  Bits are written most-significant first.")

(set! *warn-on-reflection* true)

(deftype BitBuffer [^ints words ^longs pos])

(defn buffer
  "Creates an all-zero buffer that holds `n-codewords` 8-bit codewords."
  ^BitBuffer [^long n-codewords]
  (->BitBuffer (int-array n-codewords) (long-array 1)))

(defn length
  "Number of bits written so far."
  ^long [^BitBuffer b]
  (aget ^longs (.pos b) 0))

(defn capacity
  "Capacity of the buffer in bits."
  ^long [^BitBuffer b]
  (* 8 (alength ^ints (.words b))))

(defn append!
  "Appends the low `n` bits of `value`, most significant first. Returns `b`."
  ^BitBuffer [^BitBuffer b ^long value ^long n]
  (let [words ^ints (.words b)
        p ^longs (.pos b)
        start (aget p 0)]
    (when (> (+ start n) (* 8 (alength words)))
      (throw (ex-info "Bit buffer overflow" {:length start :appending n})))
    (loop [i (dec n), at start]
      (when (>= i 0)
        (when (bit-test value i)
          (let [w (bit-shift-right at 3)]
            (aset words w (bit-or (aget words w)
                                  (bit-shift-left 1 (- 7 (bit-and at 7)))))))
        (recur (dec i) (inc at))))
    (aset p 0 (+ start n))
    b))

(defn skip!
  "Advances the write position by `n` zero bits. Returns `b`."
  ^BitBuffer [^BitBuffer b ^long n]
  (let [p ^longs (.pos b)]
    (aset p 0 (+ (aget p 0) n))
    b))

(defn codewords
  "The underlying codeword array (an int array of values 0..255)."
  ^ints [^BitBuffer b]
  (.words b))
