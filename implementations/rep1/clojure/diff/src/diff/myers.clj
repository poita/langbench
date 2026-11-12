(ns diff.myers
  "Myers' O(ND) difference algorithm in its linear-space, divide-and-conquer
  form (E. Myers, \"An O(ND) Difference Algorithm and Its Variations\", 1986,
  section 4b).

  The functions here work on sequences of integer ids (see `diff.intern`), so
  that comparing two elements is a single `int` comparison. Time is
  O((N+M)·D) and space O(N+M) beyond the inputs; recursion depth is O(log D).
  The result is always a *minimum* edit script: there are no cost cutoffs or
  heuristics."
  (:require [diff.intern :as intern]))

(set! *warn-on-reflection* true)

(defn- middle-snake
  "Finds a point (x, y) lying on some shortest edit path through the
  sub-problem a[a0, a0+n) × b[b0, b0+m), with 0 < x+y < n+m guaranteed when
  n, m > 0 and the sub-problem has no common prefix or suffix. Returns
  `[x y]` relative to (a0, b0). `vf` and `vb` are scratch arrays indexed by
  diagonal + `off`."
  [^ints a ^ints b a0 b0 n m ^ints vf ^ints vb off]
  (let [a0 (long a0) b0 (long b0) n (long n) m (long m) off (long off)
        delta (- n m)
        odd? (odd? delta)
        half (quot (+ n m 1) 2)]
    ;; Sentinels that make the d = 0 rounds pick the right "previous" cell.
    (aset vf (unchecked-int (+ off 1)) (int 0))
    (aset vb (unchecked-int (+ off delta 1)) (unchecked-int (inc n)))
    (loop [d 0]
      (when (> d half)
        (throw (ex-info "middle snake not found" {:d d})))
      ;; Forward pass over diagonals k = -d, -d+2, ..., d.
      (let [fwd
            (loop [k (- d)]
              (if (> k d)
                nil
                (let [x0 (if (or (== k (- d))
                                 (and (not= k d)
                                      (< (aget vf (unchecked-int (+ off k -1)))
                                         (aget vf (unchecked-int (+ off k 1))))))
                           (aget vf (unchecked-int (+ off k 1)))
                           (inc (aget vf (unchecked-int (+ off k -1)))))
                      y0 (- x0 k)
                      x (loop [x x0, y y0]
                          (if (and (< x n) (< y m)
                                   (== (aget a (unchecked-int (+ a0 x)))
                                       (aget b (unchecked-int (+ b0 y)))))
                            (recur (inc x) (inc y))
                            x))]
                  (aset vf (unchecked-int (+ off k)) (unchecked-int x))
                  (if (and odd?
                           (>= k (- delta (dec d))) (<= k (+ delta (dec d)))
                           (>= x (aget vb (unchecked-int (+ off k)))))
                    [x (- x k)]
                    (recur (+ k 2))))))]
        (if fwd
          fwd
          ;; Backward pass over diagonals k = delta-d, ..., delta+d.
          (let [bwd
                (loop [k (- delta d)]
                  (if (> k (+ delta d))
                    nil
                    (let [x0 (cond
                               (== k (- delta d))
                               (dec (aget vb (unchecked-int (+ off k 1))))
                               (== k (+ delta d))
                               (aget vb (unchecked-int (+ off k -1)))
                               :else
                               (min (aget vb (unchecked-int (+ off k -1)))
                                    (dec (aget vb (unchecked-int (+ off k 1))))))
                          y0 (- x0 k)
                          x (loop [x x0, y y0]
                              (if (and (> x 0) (> y 0) (<= y m)
                                       (== (aget a (unchecked-int (+ a0 x -1)))
                                           (aget b (unchecked-int (+ b0 y -1)))))
                                (recur (dec x) (dec y))
                                x))]
                      (aset vb (unchecked-int (+ off k)) (unchecked-int x))
                      (if (and (not odd?)
                               (>= k (- d)) (<= k d)
                               (<= x (aget vf (unchecked-int (+ off k)))))
                        [x (- x k)]
                        (recur (+ k 2))))))]
            (or bwd (recur (inc d)))))))))

(defn- solve!
  "Marks in `del` (over a) and `ins` (over b) the elements removed/added by a
  shortest edit script for a[a0,a1) vs b[b0,b1)."
  [^ints a ^ints b a0 a1 b0 b1
   ^booleans del ^booleans ins ^ints vf ^ints vb off]
  ;; Trim the common prefix and suffix.
  (let [a0 (long a0) a1 (long a1) b0 (long b0) b1 (long b1)
        pre (loop [i 0]
              (if (and (< (+ a0 i) a1) (< (+ b0 i) b1)
                       (== (aget a (unchecked-int (+ a0 i)))
                           (aget b (unchecked-int (+ b0 i)))))
                (recur (inc i))
                i))
        a0 (+ a0 pre)
        b0 (+ b0 pre)
        suf (loop [i 0]
              (if (and (< a0 (- a1 i)) (< b0 (- b1 i))
                       (== (aget a (unchecked-int (- a1 i 1)))
                           (aget b (unchecked-int (- b1 i 1)))))
                (recur (inc i))
                i))
        a1 (- a1 suf)
        b1 (- b1 suf)]
    (cond
      (== a0 a1) (loop [j b0] (when (< j b1) (aset ins (unchecked-int j) true) (recur (inc j))))
      (== b0 b1) (loop [i a0] (when (< i a1) (aset del (unchecked-int i) true) (recur (inc i))))
      :else
      (let [[x y] (middle-snake a b a0 b0 (- a1 a0) (- b1 b0) vf vb off)
            xm (+ a0 (long x))
            ym (+ b0 (long y))]
        (solve! a b a0 xm b0 ym del ins vf vb off)
        (solve! a b xm a1 ym b1 del ins vf vb off)))))

(defn edit-masks
  "Given two `int-array`s of line ids, returns `[deleted inserted]`: boolean
  arrays of the lengths of `a` and `b` marking the elements a minimum edit
  script deletes from `a` and inserts from `b`. The unmarked elements form a
  longest common subsequence."
  [^ints a ^ints b]
  (let [n (alength a)
        m (alength b)
        del (boolean-array n)
        ins (boolean-array m)
        size (+ (* 4 (+ n m)) 8)
        vf (int-array size)
        vb (int-array size)]
    (solve! a b 0 n 0 m del ins vf vb (+ (* 2 (+ n m)) 3))
    [del ins]))

(defn edit-masks-of
  "Like `edit-masks` but for arbitrary sequential collections of values with
  value equality; interns them first."
  [a b]
  (let [[ia ib] (intern/intern-lines a b)]
    (edit-masks ia ib)))
