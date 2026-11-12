(ns diff.intern
  "Line interning: map every distinct line to a small integer id so that the
  Myers search can compare two lines in O(1)."
  (:import (java.util HashMap)))

(set! *warn-on-reflection* true)

(defn intern-lines
  "Interns the lines of `a` and `b` (any sequential collections of values with
  value equality) against one shared table. Returns `[a-ids b-ids]`, two
  `int-array`s such that `(= (nth a i) (nth b j))` iff the ids at `i` and `j`
  are equal. Expected O(N + M)."
  [a b]
  (let [table (HashMap.)
        ids (fn [coll]
              (let [out (int-array (count coll))]
                (loop [s (seq coll), i 0]
                  (when s
                    (let [line (first s)
                          id (or (.get table line)
                                 (let [n (.size table)]
                                   (.put table line (int n))
                                   n))]
                      (aset out i (int id))
                      (recur (next s) (unchecked-inc i)))))
                out))]
    (let [x (ids a)
          y (ids b)]
      [x y])))
