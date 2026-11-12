(ns inflate.hex
  "Lowercase hexadecimal text <-> bytes. Works on ASCII byte arrays so that
  tens of megabytes can be converted without building intermediate strings.")

(set! *warn-on-reflection* true)

(def ^:private ^"[B" digits (.getBytes "0123456789abcdef" "US-ASCII"))

(defn- whitespace? [b] (or (== b 32) (and (>= b 9) (<= b 13))))

(defn- digit-value ^long [^long c]
  (cond (and (>= c 48) (<= c 57)) (- c 48)
        (and (>= c 97) (<= c 102)) (- c 87)
        (and (>= c 65) (<= c 70)) (- c 55)
        :else -1))

(defn decode-ascii
  "Decodes ASCII hex digits in `src` (a byte array; surrounding whitespace is
  ignored, either letter case accepted) into a byte array. Throws
  `IllegalArgumentException` on a non-hex character or an odd digit count."
  ^bytes [^bytes src]
  (let [n (alength src)
        start (loop [i 0] (if (and (< i n) (whitespace? (aget src i))) (recur (inc i)) i))
        end (loop [i n] (if (and (> i start) (whitespace? (aget src (dec i)))) (recur (dec i)) i))
        cnt (- end start)]
    (when (odd? cnt)
      (throw (IllegalArgumentException. "odd number of hex digits")))
    (let [out (byte-array (quot cnt 2))]
      (loop [i 0]
        (when (< i (alength out))
          (let [p (+ start (* 2 i))
                hi (digit-value (aget src p))
                lo (digit-value (aget src (inc p)))]
            (when (or (neg? hi) (neg? lo))
              (throw (IllegalArgumentException. "invalid hex digit")))
            (aset out i (unchecked-byte (+ (* 16 hi) lo)))
            (recur (inc i)))))
      out)))

(defn decode
  "Decodes the hex string `s` into a byte array."
  ^bytes [^String s]
  (decode-ascii (.getBytes s "US-ASCII")))

(defn encode-ascii
  "Encodes `data` (a byte array) as lowercase hex, returned as ASCII bytes."
  ^bytes [^bytes data]
  (let [n (alength data)
        out (byte-array (* 2 n))]
    (loop [i 0]
      (when (< i n)
        (let [b (bit-and (aget data i) 0xff)]
          (aset out (* 2 i) (aget digits (unchecked-int (bit-shift-right b 4))))
          (aset out (inc (* 2 i)) (aget digits (unchecked-int (bit-and b 15))))
          (recur (inc i)))))
    out))

(defn encode
  "Encodes `data` (a byte array) as a lowercase hex string."
  ^String [^bytes data]
  (String. (encode-ascii data) "US-ASCII"))
