(ns linalg.jacobi
  "Pieces shared by the two Jacobi-rotation algorithms (`linalg.eig` and
  `linalg.svd`).")

(set! *warn-on-reflection* true)

(defn tangent
  "The tangent `t` of the Jacobi rotation angle for the cotangent-like
  quantity `theta`: the smaller root of `t^2 + 2 theta t - 1 = 0`."
  ^double [^double theta]
  (if (>= theta 0.0)
    (/ 1.0 (+ theta (Math/sqrt (+ (* theta theta) 1.0))))
    (/ -1.0 (+ (- theta) (Math/sqrt (+ (* theta theta) 1.0))))))

(defn cosine
  "Cosine of the rotation with tangent `t`."
  ^double [^double t]
  (/ 1.0 (Math/sqrt (+ (* t t) 1.0))))

(defn order-by-value
  "The indices `0 … (count xs)-1` ordered by the double values in `xs`
  (`:asc` or `:desc`), ties broken by the smaller original index."
  [^doubles xs direction]
  (let [idx (vec (range (alength xs)))
        key-fn #(aget xs (long %))]
    (if (= direction :asc)
      (vec (sort-by key-fn < idx))
      (vec (sort-by key-fn > idx)))))
