(ns regex.charset
  "Character sets over the ASCII range, represented as `boolean-array`s of
  length 128 indexed by code point. Characters outside ASCII are never members
  of any set (the specification only matches classes against ASCII)."
  (:refer-clojure :exclude [range]))

(def ^:const size 128)

(defn empty-set
  "A new, empty character set."
  ^booleans []
  (boolean-array size))

(defn member?
  "True when character (or code point) `c` is in `set`."
  [^booleans set c]
  (let [code (long (if (char? c) (int c) c))]
    (and (<= 0 code) (< code size) (aget set code))))

(defn add-range!
  "Add every code point from `lo` to `hi` inclusive to `set` (mutating it)."
  ^booleans [^booleans set lo hi]
  (loop [c (long (int lo))]
    (when (<= c (long (int hi)))
      (aset set (int c) true)
      (recur (inc c))))
  set)

(defn union!
  "Add all members of `other` to `set` (mutating `set`)."
  ^booleans [^booleans set ^booleans other]
  (dotimes [i size]
    (when (aget other i) (aset set i true)))
  set)

(defn negate
  "A new set holding the ASCII characters not in `set`."
  ^booleans [^booleans set]
  (let [out (empty-set)]
    (dotimes [i size]
      (aset out i (not (aget set i))))
    out))

(defn singleton
  "A new set containing only character `c`."
  ^booleans [c]
  (add-range! (empty-set) c c))

(defn full
  "A new set containing every ASCII character."
  ^booleans []
  (negate (empty-set)))

(def digit
  "The set `[0-9]`."
  (add-range! (empty-set) \0 \9))

(def word
  "The set `[A-Za-z0-9_]`."
  (-> (empty-set)
      (add-range! \A \Z) (add-range! \a \z) (add-range! \0 \9) (add-range! \_ \_)))

(def space
  "Space, tab, newline, carriage return, form feed and vertical tab."
  (reduce (fn [s c] (add-range! s c c)) (empty-set)
          [\space \tab \newline \return \formfeed (char 11)]))

(def escape-sets
  "The set escapes (`\\d \\D \\w \\W \\s \\S`) keyed by their letter."
  {\d digit, \D (negate digit)
   \w word,  \W (negate word)
   \s space, \S (negate space)})
