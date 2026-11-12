(ns regex.charset
  "Character sets used by character classes and escapes.

  A set is a `boolean-array` with 129 slots: slots 0-127 say whether the
  corresponding ASCII character is a member, and slot 128 says whether *every
  non-ASCII character* is a member.  Looking a character up is therefore
  `(aget set (min (int c) 128))`.  Class contents are matched against ASCII
  code points only; a negated set (`[^a]`, `\\D`, ...) accepts non-ASCII
  characters, a plain one rejects them.")

(def ^:const size 129)

(defn empty-set
  "A new set with no members."
  ^booleans []
  (boolean-array size))

(defn member?
  "True when character code `c` is in `set`."
  [^booleans set c]
  (aget set (min (int c) 128)))

(defn add-char!
  "Adds character code `c` to `set` (mutating it) and returns the set."
  ^booleans [^booleans set c]
  (aset set (min (int c) 128) true)
  set)

(defn add-range!
  "Adds every character code from `lo` to `hi` inclusive to `set`."
  ^booleans [^booleans set lo hi]
  (loop [c (int lo)]
    (when (<= c (int hi))
      (aset set (min c 128) true)
      (recur (inc c))))
  set)

(defn union!
  "Adds all members of `src` to `dst` (mutating `dst`) and returns `dst`."
  ^booleans [^booleans dst ^booleans src]
  (dotimes [i size]
    (when (aget src i) (aset dst i true)))
  dst)

(defn negate
  "A new set holding exactly the characters that are not in `set`."
  ^booleans [^booleans set]
  (let [r (empty-set)]
    (dotimes [i size]
      (aset r i (not (aget set i))))
    r))

(defn from-ranges
  "A new set from a seq of `[lo hi]` character-code ranges."
  ^booleans [ranges]
  (let [s (empty-set)]
    (doseq [[lo hi] ranges] (add-range! s lo hi))
    s))

(defn digit "The set `\\d` = `[0-9]`." ^booleans [] (from-ranges [[48 57]]))

(defn word "The set `\\w` = `[A-Za-z0-9_]`." ^booleans []
  (from-ranges [[48 57] [65 90] [97 122] [95 95]]))

(defn space "The set `\\s`: space, tab, newline, CR, form feed, vertical tab."
  ^booleans []
  (from-ranges [[32 32] [9 13]]))

(defn escape-set
  "The set for the class escape letter `ch` (one of d D w W s S), or nil."
  ^booleans [ch]
  (case ch
    \d (digit)  \D (negate (digit))
    \w (word)   \W (negate (word))
    \s (space)  \S (negate (space))
    nil))
