(ns webhooks.base64
  "Base64 encoding (standard padded and URL-safe unpadded) and a strict
  decoder that accepts either alphabet, implemented from scratch.")

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def ^:private ^String common
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

(def ^:private ^String standard-alphabet (str common "+/"))
(def ^:private ^String url-alphabet (str common "-_"))

(defn- encode*
  ^String [^bytes bs ^String alphabet pad?]
  (let [n (alength bs)
        sb (StringBuilder. (* 4 (quot (+ n 2) 3)))]
    (loop [i 0]
      (when (< i n)
        (let [left (- n i)
              b0 (bit-and (aget bs i) 0xff)
              b1 (if (> left 1) (bit-and (aget bs (+ i 1)) 0xff) 0)
              b2 (if (> left 2) (bit-and (aget bs (+ i 2)) 0xff) 0)
              v (bit-or (bit-shift-left b0 16) (bit-shift-left b1 8) b2)]
          (.append sb (.charAt alphabet (bit-and (bit-shift-right v 18) 63)))
          (.append sb (.charAt alphabet (bit-and (bit-shift-right v 12) 63)))
          (if (> left 1)
            (.append sb (.charAt alphabet (bit-and (bit-shift-right v 6) 63)))
            (when pad? (.append sb \=)))
          (if (> left 2)
            (.append sb (.charAt alphabet (bit-and v 63)))
            (when pad? (.append sb \=)))
          (recur (+ i 3)))))
    (.toString sb)))

(defn encode
  "Standard-alphabet Base64 of byte array `bs`, padded with `=`."
  ^String [^bytes bs]
  (encode* bs standard-alphabet true))

(defn encode-url
  "URL-safe-alphabet Base64 of byte array `bs`, without padding."
  ^String [^bytes bs]
  (encode* bs url-alphabet false))

(def ^:private ^"[I" decode-table
  "Maps a character code (0-127) to its 6-bit value, or -1."
  (let [t (int-array 128 -1)]
    (dotimes [i 64]
      (aset t (int (.charAt standard-alphabet i)) (int i))
      (aset t (int (.charAt url-alphabet i)) (int i)))
    t))

(defn decode
  "Decodes Base64 text `s` to a byte array, or returns nil if `s` is invalid.

  Either alphabet is accepted but they may not be mixed. Padding is optional,
  but when present must be exactly what the encoder would emit. Left-over low
  bits in the final character are ignored. The empty string decodes to an
  empty array."
  [^String s]
  (let [len (long (.length s))
        ;; length of the body, i.e. without the trailing run of '='
        n (long (loop [n len]
                  (if (and (pos? n) (= \= (.charAt s (dec n)))) (recur (dec n)) n)))
        p (- len n)]
    (when (and (not= (rem n 4) 1)
               (<= p 2)
               (or (zero? p)
                   (case (long (rem n 4)) 3 (= p 1), 2 (= p 2), false)))
      (let [out (byte-array (quot (* n 6) 8))]
        ;; acc holds the bits not yet emitted, nbits how many there are
        (loop [i 0 acc 0 nbits 0 o 0 plus-slash? false minus-under? false]
          (if (< i n)
            (let [c (long (int (.charAt s i)))
                  v (long (if (< c 128) (aget decode-table c) -1))]
              (when (>= v 0)
                (let [ps (or plus-slash? (= c 43) (= c 47))
                      mu (or minus-under? (= c 45) (= c 95))]
                  (when-not (and ps mu)
                    (let [acc (bit-or (bit-shift-left acc 6) v)
                          nbits (+ nbits 6)]
                      (if (>= nbits 8)
                        (do (aset out o (unchecked-byte (bit-shift-right acc (- nbits 8))))
                            (recur (inc i) (bit-and acc (dec (bit-shift-left 1 (- nbits 8))))
                                   (- nbits 8) (inc o) ps mu))
                        (recur (inc i) acc nbits o ps mu)))))))
            out))))))
