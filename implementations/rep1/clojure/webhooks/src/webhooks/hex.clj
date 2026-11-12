(ns webhooks.hex
  "Strict lowercase hexadecimal encoding and decoding.")

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def ^:private ^String digits "0123456789abcdef")

(defn encode
  "Encodes a byte array as a lowercase hex string."
  ^String [^bytes bs]
  (let [n (alength bs)
        sb (StringBuilder. (* 2 n))]
    (dotimes [i n]
      (let [b (bit-and (aget bs i) 0xff)]
        (.append sb (.charAt digits (bit-shift-right b 4)))
        (.append sb (.charAt digits (bit-and b 15)))))
    (.toString sb)))

(defn- nibble ^long [^long c]
  (cond (<= 48 c 57) (- c 48)
        (<= 97 c 102) (- c 87)
        :else -1))

(defn decode
  "Decodes a string of an even number of lowercase hex digits into a byte
  array. Returns nil if `s` has odd length or any other character. The empty
  string decodes to an empty array."
  [^String s]
  (let [n (.length s)]
    (when (even? n)
      (let [out (byte-array (quot n 2))]
        (loop [i 0]
          (if (< i n)
            (let [hi (nibble (long (int (.charAt s i))))
                  lo (nibble (long (int (.charAt s (inc i)))))]
              (when (and (>= hi 0) (>= lo 0))
                (aset out (quot i 2) (unchecked-byte (+ (* hi 16) lo)))
                (recur (+ i 2))))
            out))))))
