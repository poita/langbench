(ns linalg.test-util
  "Shared helpers for the tests: matrix generators and residual checks."
  (:require [clojure.test.check.generators :as gen]
            [linalg.matrix :as m]))

(defn gen-matrix
  "Generator of `rows` x `cols` matrices with entries in [-10, 10]."
  [rows cols]
  (gen/fmap (fn [xs] (m/matrix rows cols (double-array xs)))
            (gen/vector (gen/double* {:min -10.0 :max 10.0 :NaN? false :infinite? false})
                        (* rows cols))))

(defn gen-dims
  "Generator of `[rows cols]` pairs, each between 1 and `max-dim`."
  [max-dim]
  (gen/tuple (gen/choose 1 max-dim) (gen/choose 1 max-dim)))

(defn gen-any-matrix [max-dim]
  (gen/bind (gen-dims max-dim) (fn [[r c]] (gen-matrix r c))))

(defn gen-square [max-dim]
  (gen/bind (gen/choose 1 max-dim) #(gen-matrix % %)))

(defn gen-tall [max-dim]
  (gen/bind (gen/tuple (gen/choose 1 max-dim) (gen/choose 0 max-dim))
            (fn [[n extra]] (gen-matrix (+ n extra) n))))

(defn gen-symmetric [max-dim]
  (gen/fmap (fn [a] (m/matrix (m/rows a) (m/cols a)
                              (:data (m/mul (m/add a (m/transpose a))
                                            (m/identity-matrix (m/cols a))))))
            (gen-square max-dim)))

(defn max-abs
  "The largest absolute entry of `a`."
  [a]
  (reduce max 0.0 (map #(Math/abs (double %)) (:data a))))

(defn scale-matrix [a x]
  (m/matrix (m/rows a) (m/cols a) (double-array (map #(* x %) (:data a)))))

(defn sub [a b] (m/add a (scale-matrix b -1.0)))

(defn diag-matrix [v]
  (let [n (m/rows v)
        d (double-array (* n n))]
    (dotimes [i n] (aset d (+ (* i n) i) (m/entry v i 0)))
    (m/matrix n n d)))

(defn close?
  "True when `a` and `b` agree to `tol` times the larger of 1 and `scale`."
  ([a b] (close? a b 1e-9))
  ([a b tol]
   (m/approx= a b (* tol (max 1.0 (max-abs a) (max-abs b))))))

(defn orthonormal-columns? [q]
  (close? (m/mul (m/transpose q) q) (m/identity-matrix (m/cols q)) 1e-9))

(defn upper-triangular? [a]
  (every? true? (for [i (range (m/rows a)) j (range (min i (m/cols a)))]
                  (== 0.0 (m/entry a i j)))))

(defn lower-triangular? [a]
  (upper-triangular? (m/transpose a)))

(defn thrown-code
  "Runs `f` and returns the linalg error code it throws, or nil."
  [f]
  (try (f) nil
       (catch clojure.lang.ExceptionInfo e (:linalg/error (ex-data e)))))
