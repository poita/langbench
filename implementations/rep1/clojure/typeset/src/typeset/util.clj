(ns typeset.util
  "Small shared helpers: exact integer arithmetic, numeral formatting and the
  error type used to report invalid input."
  (:import (java.math BigInteger)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Arithmetic

(defn fdiv
  "Floor division `a div b` for `b > 0`."
  ^long [^long a ^long b]
  (Math/floorDiv a b))

(defn scale
  "Scale a glyph-space quantity `u` (1/1000 em) to millipoints at size `s`:
  `(u * s) div 1000`."
  ^long [^long u ^long s]
  (Math/floorDiv (* u s) 1000))

(defn cube-ratio
  "`(100 * d^3) div y^3` computed exactly for `d >= 0`, `y > 0`, clamped to
  10000 (the maximum badness)."
  ^long [^long d ^long y]
  (cond
    (> d (* 5 y)) 10000
    (and (< d 100000) (< y 2000000))
    (min 10000 (quot (* 100 d d d) (* y y y)))
    :else
    (let [bd (BigInteger/valueOf d)
          by (BigInteger/valueOf y)
          q  (.divide (.multiply (BigInteger/valueOf 100) (.pow bd 3)) (.pow by 3))]
      (if (> (.compareTo q (BigInteger/valueOf 10000)) 0) 10000 (.longValue q)))))

;; ---------------------------------------------------------------------------
;; Numerals

(def ^:private roman-pairs
  [[1000 "m"] [900 "cm"] [500 "d"] [400 "cd"] [100 "c"] [90 "xc"]
   [50 "l"] [40 "xl"] [10 "x"] [9 "ix"] [5 "v"] [4 "iv"] [1 "i"]])

(defn roman
  "Lowercase roman numeral of `n` by greedy subtraction (unchanged above 3999)."
  [n]
  (let [sb (StringBuilder.)]
    (loop [n (long n) ps roman-pairs]
      (when (and (pos? n) (seq ps))
        (let [[v s] (first ps)]
          (if (>= n v)
            (do (.append sb ^String s) (recur (- n (long v)) ps))
            (recur n (rest ps))))))
    (str sb)))

(defn letters
  "Bijective base-26 lowercase letters: 1 -> a, 26 -> z, 27 -> aa."
  [n]
  (loop [n (long n) acc '()]
    (if (pos? n)
      (let [m (dec n)]
        (recur (quot m 26) (cons (char (+ 97 (rem m 26))) acc)))
      (apply str acc))))

;; ---------------------------------------------------------------------------
;; Code points

(defn code-points
  "The code points of string `s` as an int array."
  ^ints [^String s]
  (.toArray (.codePoints s)))

(defn cps->str
  "Build a string from `n` code points of `cps` starting at `from`."
  ^String [^ints cps ^long from ^long to]
  (let [sb (StringBuilder.)]
    (loop [i from]
      (when (< i to)
        (.appendCodePoint sb (aget cps i))
        (recur (inc i))))
    (str sb)))

(defn space? [^long c] (== c 32))

;; ---------------------------------------------------------------------------
;; Errors

(defn fail
  "Abort processing with an input error at `file:line:col`."
  [file line col code]
  (throw (ex-info (str "input error: " code)
                  {:typeset/error {:file file :line line :col col :code code}})))

(defn input-error
  "The error map carried by an exception thrown by `fail`, or nil."
  [^Throwable e]
  (:typeset/error (ex-data e)))

(defn error-line
  "The one-line text of `error.txt` for an error map."
  [{:keys [file line col code]}]
  (str file ":" line ":" col ": " code))
