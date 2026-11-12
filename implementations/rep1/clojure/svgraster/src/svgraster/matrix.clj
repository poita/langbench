(ns svgraster.matrix
  "2D affine transforms.

  A matrix is a vector `[a b c d e f]` meaning

      x' = a*x + c*y + e
      y' = b*x + d*y + f

  which is the argument order of the SVG `matrix(a b c d e f)` transform.")

(set! *warn-on-reflection* true)

(def identity-matrix [1.0 0.0 0.0 1.0 0.0 0.0])

(defn multiply
  "The matrix `m * n`: applying the result is applying `n` first, then `m`."
  [[a1 b1 c1 d1 e1 f1] [a2 b2 c2 d2 e2 f2]]
  (let [a1 (double a1) b1 (double b1) c1 (double c1) d1 (double d1)
        e1 (double e1) f1 (double f1) a2 (double a2) b2 (double b2)
        c2 (double c2) d2 (double d2) e2 (double e2) f2 (double f2)]
    [(+ (* a1 a2) (* c1 b2))
     (+ (* b1 a2) (* d1 b2))
     (+ (* a1 c2) (* c1 d2))
     (+ (* b1 c2) (* d1 d2))
     (+ (* a1 e2) (* c1 f2) e1)
     (+ (* b1 e2) (* d1 f2) f1)]))

(defn translate [tx ty] [1.0 0.0 0.0 1.0 (double tx) (double ty)])

(defn scale [sx sy] [(double sx) 0.0 0.0 (double sy) 0.0 0.0])

(defn rotate
  "Rotation by `degrees` (positive: +x towards +y) about the origin."
  [degrees]
  (let [r (Math/toRadians (double degrees))
        c (Math/cos r)
        s (Math/sin r)]
    [c s (- s) c 0.0 0.0]))

(defn determinant ^double [[a b c d]]
  (- (* (double a) (double d)) (* (double b) (double c))))

(defn scale-factor
  "The linear scale a matrix applies to lengths, sqrt(|det|); 1.0 when the
  matrix is singular or not finite."
  ^double [m]
  (let [s (Math/sqrt (Math/abs (determinant m)))]
    (if (and (Double/isFinite s) (pos? s)) s 1.0)))

(defn transform-point
  "Maps the point (x, y); returns `[x' y']`."
  [[a b c d e f] x y]
  (let [x (double x) y (double y)]
    [(+ (* (double a) x) (* (double c) y) (double e))
     (+ (* (double b) x) (* (double d) y) (double f))]))

(defn transform-points
  "Maps a flat `double[]` of x,y pairs; returns a new `double[]`."
  ^doubles [m ^doubles pts]
  (let [[a b c d e f] m
        a (double a) b (double b) c (double c) d (double d)
        e (double e) f (double f)
        n (alength pts)
        out (double-array n)]
    (loop [i 0]
      (when (< i n)
        (let [x (aget pts i) y (aget pts (inc i))]
          (aset out i (+ (* a x) (* c y) e))
          (aset out (inc i) (+ (* b x) (* d y) f)))
        (recur (+ i 2))))
    out))
