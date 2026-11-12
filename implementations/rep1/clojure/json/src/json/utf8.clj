(ns json.utf8
  "Strict UTF-8 validation (RFC 3629).")

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(defmacro ^:private ub
  "Unsigned value of the byte at index `i` of `buf`."
  [buf i]
  `(bit-and (long (aget ~buf (long ~i))) 0xFF))

(defmacro ^:private byte-in?
  "True if index `i` is inside `buf` (of length `n`) and the unsigned byte
  there lies in [lo, hi]."
  [buf i n lo hi]
  `(let [i# (long ~i)]
     (and (< i# (long ~n))
          (let [b# (ub ~buf i#)]
            (and (>= b# ~lo) (<= b# ~hi))))))

(defn valid?
  "True if the whole byte array `buf` is well-formed UTF-8: no overlong
  encodings, no encoded surrogates, nothing above U+10FFFF and no truncated
  sequences. A single forward pass; does not allocate."
  [^bytes buf]
  (let [n (alength buf)]
    (loop [i 0]
      (if (>= i n)
        true
        (let [b (ub buf i)]
          (cond
            (< b 0x80) (recur (inc i))
            (< b 0xC2) false
            (< b 0xE0) (and (byte-in? buf (inc i) n 0x80 0xBF)
                            (recur (+ i 2)))
            (< b 0xF0) (let [lo (if (== b 0xE0) 0xA0 0x80)
                             hi (if (== b 0xED) 0x9F 0xBF)]
                         (and (byte-in? buf (inc i) n lo hi)
                              (byte-in? buf (+ i 2) n 0x80 0xBF)
                              (recur (+ i 3))))
            (< b 0xF5) (let [lo (if (== b 0xF0) 0x90 0x80)
                             hi (if (== b 0xF4) 0x8F 0xBF)]
                         (and (byte-in? buf (inc i) n lo hi)
                              (byte-in? buf (+ i 2) n 0x80 0xBF)
                              (byte-in? buf (+ i 3) n 0x80 0xBF)
                              (recur (+ i 4))))
            :else false))))))
