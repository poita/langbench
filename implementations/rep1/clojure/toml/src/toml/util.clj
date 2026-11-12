(ns toml.util
  "Small helpers shared by several modules."
  (:import (java.util Arrays Comparator)))

(set! *warn-on-reflection* true)

(defn- fix-surrogate
  "Maps a UTF-16 code unit to a value whose numeric order is code point order."
  ^long [^long c]
  (cond (< c 0xD800) c
        (< c 0xE000) (+ c 0x2000)   ; surrogates sort after every BMP unit
        :else (- c 0x800)))

(defn compare-code-points
  "Compares two strings by Unicode code point (not by UTF-16 code unit as
  `String.compareTo` does)."
  ^long [^String a ^String b]
  (let [la (.length a) lb (.length b) n (min la lb)]
    (loop [i 0]
      (if (< i n)
        (let [ca (long (int (.charAt a i))) cb (long (int (.charAt b i)))]
          (if (== ca cb)
            (recur (unchecked-inc i))
            (Long/compare (fix-surrogate ca) (fix-surrogate cb))))
        (Long/compare la lb)))))

(def ^Comparator code-point-comparator
  (reify Comparator
    (compare [_ a b] (int (compare-code-points a b)))))

(defn sorted-keys
  "Returns the string keys of map `m` as an array in code point order."
  ^objects [m]
  (let [arr ^objects (to-array (keys m))]
    (Arrays/sort arr code-point-comparator)
    arr))
