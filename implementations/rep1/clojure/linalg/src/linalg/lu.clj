(ns linalg.lu
  "LU factorisation with partial pivoting and the operations built on it:
  determinant, linear solve and inverse. Nothing is cached between calls."
  (:require [linalg.error :as err]
            [linalg.matrix :as m])
  (:import (linalg.matrix Matrix)))

(set! *warn-on-reflection* true)

(defn- eliminate
  "Right-looking Gaussian elimination with partial pivoting on a copy of the
  square matrix `a`. Returns a map with `:lu` (the packed multipliers and U,
  row-major `double[]`), `:perm` (`int[]`), `:swaps` (number of row swaps) and
  `:singular?`, true when a pivot was exactly zero (elimination stops there)."
  [^Matrix a]
  (let [n (.rows a)
        ^doubles lu (aclone ^doubles (.data a))
        ^ints perm (int-array (range n))]
    (loop [k 0 swaps 0]
      (if (== k n)
        {:lu lu :perm perm :swaps swaps :singular? false}
        (let [p (loop [i (inc k) p k best (Math/abs (aget lu (+ (* k n) k)))]
                  (if (< i n)
                    (let [v (Math/abs (aget lu (+ (* i n) k)))]
                      (if (> v best) (recur (inc i) i v) (recur (inc i) p best)))
                    p))]
          (if (== 0.0 (Math/abs (aget lu (+ (* p n) k))))
            {:lu lu :perm perm :swaps swaps :singular? true}
            (do
              (when (not= p k)
                (dotimes [j n]
                  (let [x (+ (* k n) j) y (+ (* p n) j) t (aget lu x)]
                    (aset lu x (aget lu y))
                    (aset lu y t)))
                (let [t (aget perm k)] (aset perm k (aget perm p)) (aset perm p t)))
              (let [pivot (aget lu (+ (* k n) k))]
                (loop [i (inc k)]
                  (when (< i n)
                    (let [f (/ (aget lu (+ (* i n) k)) pivot)]
                      (aset lu (+ (* i n) k) f)
                      (loop [j (inc k)]
                        (when (< j n)
                          (aset lu (+ (* i n) j)
                                (- (aget lu (+ (* i n) j)) (* f (aget lu (+ (* k n) j)))))
                          (recur (inc j)))))
                    (recur (inc i)))))
              (recur (inc k) (if (not= p k) (inc swaps) swaps)))))))))

(defn- check-square [^Matrix a]
  (when-not (m/square? a) (err/fail! :not-square)))

(defn- factor
  "Eliminates `a`, throwing `:not-square` or `:singular`."
  [a]
  (check-square a)
  (let [r (eliminate a)]
    (when (:singular? r) (err/fail! :singular))
    r))

(defn lu
  "Factors the square matrix `a` as `P A = L U` with partial pivoting.
  Returns a map:

  * `:P` permutation matrix with `P[i][perm[i]] = 1`
  * `:L` unit lower triangular
  * `:U` upper triangular
  * `:perm` vector, `perm[i]` is the original row now in row `i`
  * `:swaps` number of row interchanges performed

  Throws `:not-square` or `:singular`."
  [^Matrix a]
  (let [{:keys [^doubles lu ^ints perm swaps]} (factor a)
        n (.rows a)
        p (double-array (* n n))
        l (double-array (* n n))
        u (double-array (* n n))]
    (dotimes [i n]
      (aset p (+ (* i n) (aget perm i)) 1.0)
      (aset l (+ (* i n) i) 1.0)
      (dotimes [j n]
        (let [k (+ (* i n) j) x (aget lu k)]
          (cond (< j i) (aset l k x)
                :else (aset u k x)))))
    {:P (m/matrix n n p) :L (m/matrix n n l) :U (m/matrix n n u)
     :perm (vec perm) :swaps swaps}))

(defn det
  "The determinant of the square matrix `a`: the product of the diagonal of U
  in increasing order times `(-1)^swaps`. A singular matrix has determinant
  0.0; `det` never throws `:singular`."
  ^double [^Matrix a]
  (check-square a)
  (let [r (eliminate a)]
    (if (:singular? r)
      0.0
      (let [^doubles lu (:lu r) n (.rows a)
            prod (loop [i 0 p 1.0] (if (< i n) (recur (inc i) (* p (aget lu (+ (* i n) i)))) p))]
        (if (even? (long (:swaps r))) prod (- prod))))))

(defn solve
  "Solves `A X = B` for `X`, one column of `B` at a time: permute, forward
  substitution through L, back substitution through U. `a` must be square
  (`:not-square`), `b` must have as many rows (`:dimension-mismatch`), and `a`
  must be nonsingular (`:singular`)."
  [^Matrix a ^Matrix b]
  (check-square a)
  (when-not (== (.rows a) (.rows b)) (err/fail! :dimension-mismatch))
  (let [{:keys [^doubles lu ^ints perm]} (factor a)
        n (.rows a) k (.cols b)
        ^doubles bd (.data b)
        out (double-array (* n k))
        x (double-array n)]
    (dotimes [c k]
      (dotimes [i n]
        (let [s (double (loop [j 0 s (aget bd (+ (* (aget perm i) k) c))]
                          (if (< j i) (recur (inc j) (- s (* (aget lu (+ (* i n) j)) (aget x j)))) s)))]
          (aset x i s)))
      (loop [i (dec n)]
        (when (>= i 0)
          (let [s (double (loop [j (inc i) s (aget x i)]
                            (if (< j n) (recur (inc j) (- s (* (aget lu (+ (* i n) j)) (aget x j)))) s)))]
            (aset x i (/ s (aget lu (+ (* i n) i)))))
          (recur (dec i))))
      (dotimes [i n] (aset out (+ (* i k) c) (aget x i))))
    (m/matrix n k out)))

(defn inverse
  "The inverse of the square matrix `a`, computed as `solve a I`.
  Throws `:not-square` or `:singular`."
  [^Matrix a]
  (check-square a)
  (solve a (m/identity-matrix (.rows a))))
