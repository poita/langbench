(ns diff.core
  "Public API of the library: shortest edit scripts between two sequences of
  lines (Myers' algorithm, exact, linear space) and applying edit scripts.

  An *edit* is `[op line]` where `op` is `:keep`, `:delete` or `:insert`; a
  *script* is a vector of edits in file order.

      (require '[diff.core :as diff])
      (diff/diff [\"a\" \"b\" \"c\"] [\"a\" \"c\" \"d\"])
      ;=> [[:keep \"a\"] [:delete \"b\"] [:keep \"c\"] [:insert \"d\"]]
      (diff/patch [\"a\" \"b\" \"c\"] *1)
      ;=> [\"a\" \"c\" \"d\"]"
  (:require [diff.myers :as myers]
            [diff.script :as script]))

(defn diff
  "Returns a minimum-cost edit script turning the lines `a` into the lines
  `b`. Lines may be any values with value equality (typically strings).
  Runs in O((N+M)·D) time and O(N+M) space, where D is the script's cost."
  [a b]
  (let [[del ins] (myers/edit-masks-of a b)]
    (script/from-masks a b del ins)))

(defn patch
  "Applies the edit `script` to the lines `a` and returns the resulting lines
  as a vector. The script need not be minimal. Throws `ex-info` when the
  script is not valid for `a`."
  [a script]
  (script/apply-script a script))

(defn cost
  "The cost of `script`: its number of deletions plus insertions."
  [script]
  (script/cost script))

(defn format-script
  "Renders `script` as a vector of text lines (tag character + line)."
  [script]
  (script/render script))

(defn parse-script
  "Inverse of `format-script`."
  [lines]
  (script/parse lines))
