(ns depresolve.range
  "Version ranges.  Every range of the input language denotes a half-open
  interval `[lo, hi)` of packed versions (see `depresolve.version`), so a
  range is represented as the pair `[lo hi]`.  A range with `lo >= hi`
  accepts nothing."
  (:require [clojure.string :as str]
            [depresolve.version :as v]))

(set! *warn-on-reflection* true)

(def ^:const ^long max-version Long/MAX_VALUE)

(defn- caret [^long x ^long y ^long z]
  (let [lo (v/pack x y z)]
    [lo (cond (pos? x) (v/pack (inc x) 0 0)
              (pos? y) (v/pack 0 (inc y) 0)
              :else    (inc lo))]))

(defn- tilde [^long x ^long y ^long z]
  [(v/pack x y z) (v/pack x (inc y) 0)])

(defn- comparator-interval [^String c]
  (let [two? (= \= (.charAt c 1))
        op   (.substring c 0 (if two? 2 1))
        ver  (v/parse (.substring c (count op)))]
    (case op
      "<"  [0 ver]
      "<=" [0 (inc ver)]
      ">"  [(inc ver) max-version]
      ">=" [ver max-version])))

(defn parse
  "Parses a range string (`*`, `1.2.3`, `^1.2.3`, `~1.2.3`, or one or more
  space-separated comparators such as `>=1.0.0 <2.0.0`) into `[lo hi)`,
  returned as the vector `[lo hi]` of packed versions."
  [^String s]
  (let [c (.charAt s 0)]
    (cond
      (= c \*) [0 max-version]
      (= c \^) (let [x (v/parse (subs s 1))]
                 (caret (v/major x) (v/minor x) (v/patch x)))
      (= c \~) (let [x (v/parse (subs s 1))]
                 (tilde (v/major x) (v/minor x) (v/patch x)))
      (Character/isDigit c) (let [x (v/parse s)] [x (inc x)])
      :else (reduce (fn [[lo hi] cmp]
                      (let [[l h] (comparator-interval cmp)]
                        [(max lo l) (min hi h)]))
                    [0 max-version]
                    (str/split s #" ")))))

(defn in-range?
  "True when the packed version `ver` lies in the range `[lo hi]`."
  [[lo hi] ^long ver]
  (and (<= ^long lo ver) (< ver ^long hi)))
