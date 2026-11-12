(ns bigint.decimal
  "Conversion between decimal strings and magnitudes (see `bigint.magnitude`).
  Both directions are linear in the number of digits because the limb base is
  a power of ten."
  (:require [bigint.magnitude :as mag]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(defn ^longs parse-digits
  "Parses the decimal digits in `s` between indices `start` (inclusive) and
  `end` (exclusive) into a normalised magnitude. Leading zeros are allowed.
  Throws `ex-info` with `:type ::bad-digit` on any non-digit character."
  [^String s ^long start ^long end]
  (let [;; skip leading zeros
        start (long (loop [i start]
                (if (and (< i end) (== (int \0) (int (.charAt s (int i)))))
                  (recur (inc i))
                  i)))
        len (- end start)]
    (if (<= len 0)
      mag/zero
      (let [nlimbs (quot (+ len (dec mag/base-digits)) mag/base-digits)
            r (long-array nlimbs)]
        ;; Fill limbs from the least-significant end.
        (loop [k 0 hi end]
          (when (< k nlimbs)
            (let [lo (Math/max start (- hi (long mag/base-digits)))
                  v (long (loop [i lo acc 0]
                      (if (< i hi)
                        (let [d (- (int (.charAt s (int i))) (int \0))]
                          (when (or (< d 0) (> d 9))
                            (throw (ex-info "Not a decimal digit"
                                            {:type ::bad-digit :input s :index i})))
                          (recur (inc i) (+ (* acc 10) d)))
                        acc)))]
              (aset r k v)
              (recur (inc k) lo))))
        r))))

(defn append-magnitude
  "Appends the decimal digits of magnitude `a` (no sign, no leading zeros;
  \"0\" for zero) to the StringBuilder `sb`."
  [^StringBuilder sb ^longs a]
  (let [n (alength a)]
    (if (== n 0)
      (.append sb \0)
      (do
        (.append sb (aget a (dec n)))
        (loop [k (- n 2)]
          (when (>= k 0)
            (let [limb (aget a k)]
              ;; zero-padded to 9 digits
              (loop [div 100000000]
                (when (> div 0)
                  (.append sb (char (+ (int \0) (int (rem (quot limb div) 10)))))
                  (recur (quot div 10)))))
            (recur (dec k))))))
    sb))

(defn magnitude->string
  "Canonical decimal string of magnitude `a`."
  ^String [^longs a]
  (str (append-magnitude (StringBuilder. (* 9 (inc (alength a)))) a)))
