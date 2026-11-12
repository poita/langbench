(ns depresolve.version
  "Semantic versions `MAJOR.MINOR.PATCH`.

  A version is a vector of three non-negative integers, `[major minor patch]`.
  Because all vectors have the same length, Clojure's `compare` orders them
  numerically component by component (so `[1 10 0]` is newer than `[1 9 0]`).

  For fast comparison the search engine also uses an *encoded* form: a single
  `long` that preserves the ordering of versions whose components are at most
  `max-component`.")

(set! *warn-on-reflection* true)

(def ^:const max-component
  "Largest component value that `encode` supports (the spec's bound is 1,000,000)."
  (dec (bit-shift-left 1 21)))

(defn parse
  "Parses \"X.Y.Z\" into `[X Y Z]`."
  [^String s]
  (let [i (.indexOf s ".")
        j (.indexOf s "." (inc i))]
    [(Long/parseLong (subs s 0 i))
     (Long/parseLong (subs s (inc i) j))
     (Long/parseLong (subs s (inc j)))]))

(defn fmt
  "Formats `[X Y Z]` as \"X.Y.Z\"."
  [[x y z]]
  (str x "." y "." z))

(defn successor
  "The smallest version strictly greater than `v` (bumps the patch component).
  Used to turn inclusive bounds into exclusive ones."
  [[x y z]]
  [x y (inc (long z))])

(defn encode
  "Encodes a version vector as an order-preserving `long`."
  ^long [[x y z]]
  (bit-or (bit-shift-left (long x) 42)
          (bit-or (bit-shift-left (long y) 21) (long z))))

(defn decode
  "Inverse of `encode`."
  [^long k]
  (let [m max-component]
    [(bit-shift-right k 42)
     (bit-and (bit-shift-right k 21) m)
     (bit-and k m)]))

(defn newer?
  "True when `a` is a strictly newer version than `b`."
  [a b]
  (pos? (compare a b)))

(defn valid?
  "True when `v` is a well-formed version vector."
  [v]
  (and (vector? v) (= 3 (count v)) (every? #(and (integer? %) (not (neg? %))) v)))
