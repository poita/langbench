(ns minisql.like
  "SQL `LIKE` matching: `%` matches any run of characters, `_` exactly one,
  everything else itself; ASCII letters match case-insensitively.

  The matcher is the classic two-pointer wildcard algorithm with a single
  backtrack point (the most recent `%`): O(|s|·|p|) worst case, no regular
  expressions.")

(defn- code-points
  "Code points of `s`, with ASCII upper-case letters folded to lower case."
  ^ints [^String s]
  (let [^ints a (.toArray (.codePoints s))]
    (dotimes [i (alength a)]
      (let [c (aget a i)]
        (when (and (>= c 65) (<= c 90))
          (aset a i (+ c 32)))))
    a))

(defn like?
  "True if text `s` matches `pattern` (both strings)."
  [^String s ^String pattern]
  (let [^ints t (code-points s)
        ^ints p (code-points pattern)
        n (alength t)
        m (alength p)
        pct (int 37) under (int 95)]
    (loop [si 0, pi 0, star -1, mark 0]
      (cond
        (< si n)
        (cond
          (and (< pi m) (== (aget p pi) pct))
          (recur si (inc pi) pi si)

          (and (< pi m) (or (== (aget p pi) under) (== (aget p pi) (aget t si))))
          (recur (inc si) (inc pi) star mark)

          (>= star 0)
          (recur (inc mark) (inc star) star (inc mark))

          :else false)

        :else
        (loop [pi pi]
          (cond (>= pi m) true
                (== (aget p pi) pct) (recur (inc pi))
                :else false))))))
