(ns softfloat.hex
  "Conversion between binary32 bit patterns and their 8-digit hex text.")

(set! *warn-on-reflection* true)

(defn parse
  "Parse hexadecimal text (e.g. \"3f800000\") into a pattern (a long)."
  ^long [^String s]
  (Long/parseLong s 16))

(defn append-hex8!
  "Append pattern `x` to StringBuilder `sb` as exactly 8 lowercase hex digits."
  [^StringBuilder sb ^long x]
  (let [digits "0123456789abcdef"]
    (loop [i 28]
      (when (>= i 0)
        (.append sb (.charAt ^String digits (int (bit-and (bit-shift-right x i) 15))))
        (recur (- i 4))))
    sb))

(defn format-bits
  "Format pattern `x` as exactly 8 lowercase hex digits."
  ^String [^long x]
  (str (append-hex8! (StringBuilder. 8) x)))
