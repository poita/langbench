(ns linalg.matrix
  "A dense real matrix over `double`, with elementwise operations,
  multiplication, transpose and the norms.

  A matrix is a [[Matrix]] record: `rows`, `cols`, and `data`, a `double[]`
  holding the entries in row-major order. Operations never mutate their
  arguments. All sums are single running sums in the order documented on each
  function (no pairwise or compensated summation)."
  (:require [linalg.error :as err]))

(set! *warn-on-reflection* true)

(defrecord Matrix [^long rows ^long cols data])

(defn matrix
  "Builds a `rows` x `cols` matrix that owns the row-major `double[]` `data`."
  [rows cols ^doubles data]
  (assert (= (alength data) (* rows cols)) "data length must equal rows*cols")
  (->Matrix rows cols data))

(defn zeros
  "A `rows` x `cols` matrix of zeros."
  [rows cols]
  (matrix rows cols (double-array (* (long rows) (long cols)))))

(defn identity-matrix
  "The `n` x `n` identity matrix."
  [n]
  (let [n (long n)
        d (double-array (* n n))]
    (dotimes [i n] (aset d (+ (* i n) i) 1.0))
    (matrix n n d)))

(defn from-rows
  "Builds a matrix from a sequence of equal-length sequences of numbers.
  `(from-rows [[1 2] [3 4]])` is the 2x2 matrix with first row 1 2."
  [rows]
  (let [rows (mapv vec rows)
        m (count rows)
        n (count (first rows))]
    (assert (every? #(= n (count %)) rows) "ragged rows")
    (matrix m n (double-array (map double (apply concat rows))))))

(defn to-rows
  "The matrix as a vector of row vectors of doubles."
  [^Matrix a]
  (let [n (.cols a) ^doubles d (.data a)]
    (vec (for [i (range (.rows a))]
           (vec (for [j (range n)] (aget d (+ (* i n) j))))))))

(defn rows "Number of rows." ^long [^Matrix a] (.rows a))
(defn cols "Number of columns." ^long [^Matrix a] (.cols a))
(defn shape "`[rows cols]`." [^Matrix a] [(.rows a) (.cols a)])
(defn square? "True when the matrix has as many rows as columns."
  [^Matrix a] (== (.rows a) (.cols a)))

(defn entry
  "The entry in row `i`, column `j` (0-based)."
  ^double [^Matrix a ^long i ^long j]
  (aget ^doubles (.data a) (+ (* i (.cols a)) j)))

(defn scalar
  "A 1x1 matrix holding `x`."
  [x]
  (matrix 1 1 (double-array [x])))

(defn column-vector
  "An n x 1 matrix holding the numbers of `xs`."
  [xs]
  (let [d (double-array xs)] (matrix (alength d) 1 d)))

(defn symmetric?
  "True when the matrix is square and `A[i][j] == A[j][i]` for all `i`, `j`,
  compared as exact doubles."
  [^Matrix a]
  (and (square? a)
       (let [n (.cols a) ^doubles d (.data a)]
         (loop [i 0]
           (cond (== i n) true
                 (loop [j 0]
                   (cond (== j i) true
                         (== (aget d (+ (* i n) j)) (aget d (+ (* j n) i))) (recur (inc j))
                         :else false)) (recur (inc i))
                 :else false)))))

(defn approx=
  "True when `a` and `b` have the same shape and every pair of entries differs
  by at most `tol` (absolute)."
  [a b tol]
  (and (= (shape a) (shape b))
       (let [^doubles x (:data a) ^doubles y (:data b)]
         (loop [i 0]
           (cond (== i (alength x)) true
                 (<= (Math/abs (- (aget x i) (aget y i))) (double tol)) (recur (inc i))
                 :else false)))))

(defn transpose
  "The `n` x `m` transpose of an `m` x `n` matrix."
  [^Matrix a]
  (let [m (.rows a) n (.cols a) ^doubles d (.data a)
        t (double-array (* m n))]
    (dotimes [i m]
      (dotimes [j n]
        (aset t (+ (* j m) i) (aget d (+ (* i n) j)))))
    (matrix n m t)))

(defn add
  "Elementwise sum of two matrices of the same shape.
  Throws `:dimension-mismatch` otherwise."
  [^Matrix a ^Matrix b]
  (when-not (= (shape a) (shape b)) (err/fail! :dimension-mismatch))
  (let [^doubles x (.data a) ^doubles y (.data b)
        r (double-array (alength x))]
    (dotimes [i (alength x)] (aset r i (+ (aget x i) (aget y i))))
    (matrix (.rows a) (.cols a) r)))

(defn mul
  "The product of an `m` x `k` and a `k` x `n` matrix, each entry one running
  sum over increasing `k`. Throws `:dimension-mismatch` when the inner
  dimensions differ."
  [^Matrix a ^Matrix b]
  (when-not (== (.cols a) (.rows b)) (err/fail! :dimension-mismatch))
  (let [m (.rows a) kk (.cols a) n (.cols b)
        ^doubles x (.data a)
        ^doubles bt (.data ^Matrix (transpose b))      ; row j of bt is column j of b
        r (double-array (* m n))]
    (dotimes [i m]
      (dotimes [j n]
        (let [ia (* i kk) jb (* j kk)]
          (aset r (+ (* i n) j)
                (double (loop [k 0 s 0.0]
                          (if (< k kk)
                            (recur (inc k) (+ s (* (aget x (+ ia k)) (aget bt (+ jb k)))))
                            s)))))))
    (matrix m n r)))

(defn norm1
  "The maximum over columns of the sum of absolute values, each column summed
  over increasing row index."
  ^double [^Matrix a]
  (let [m (.rows a) n (.cols a) ^doubles d (.data a)]
    (loop [j 0 best 0.0]
      (if (< j n)
        (let [s (double (loop [i 0 s 0.0]
                          (if (< i m) (recur (inc i) (+ s (Math/abs (aget d (+ (* i n) j))))) s)))]
          (recur (inc j) (if (> s best) s best)))
        best))))

(defn norminf
  "The maximum over rows of the sum of absolute values, each row summed over
  increasing column index."
  ^double [^Matrix a]
  (let [m (.rows a) n (.cols a) ^doubles d (.data a)]
    (loop [i 0 best 0.0]
      (if (< i m)
        (let [s (double (loop [j 0 s 0.0]
                          (if (< j n) (recur (inc j) (+ s (Math/abs (aget d (+ (* i n) j))))) s)))]
          (recur (inc i) (if (> s best) s best)))
        best))))

(defn normfro
  "The Frobenius norm: the square root of the sum of squares, accumulated in
  row-major order."
  ^double [^Matrix a]
  (let [^doubles d (.data a)]
    (Math/sqrt (loop [i 0 s 0.0]
                 (if (< i (alength d))
                   (let [x (aget d i)] (recur (inc i) (+ s (* x x))))
                   s)))))
