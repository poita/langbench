(ns svgraster.stroke-test
  (:require [clojure.test :refer [deftest is testing]]
            [svgraster.raster :as raster]
            [svgraster.stroke :as stroke]))

(defn- sub [pts closed?] {:points (double-array pts) :closed? closed?})

(defn- area
  "Area of the union of `polys` measured with the rasteriser on a 40x40 canvas."
  [polys]
  (let [c (raster/new-canvas 40 40)]
    (raster/fill-polygons! c (map raster/orient-positive polys) :nonzero [0.0 0.0 0.0] 1.0)
    (let [^doubles d (:data c)]
      (reduce + (for [i (range 3 (alength d) 4)] (aget d i))))))

(defn- approx [a b tol] (< (Math/abs (- (double a) (double b))) tol))

(def opts {:width 4.0 :cap :butt :join :miter :miter-limit 4.0 :tolerance 0.01})

(deftest single-segment
  (let [polys (stroke/stroke-polygons [(sub [10 20 30 20] false)] opts)]
    (is (= 1 (count polys)) "butt caps add nothing")
    (is (approx 80.0 (area polys) 1e-6)))
  (testing "square caps extend by half the width at both ends"
    (is (approx 96.0 (area (stroke/stroke-polygons [(sub [10 20 30 20] false)]
                                                   (assoc opts :cap :square))) 1e-6)))
  (testing "round caps add a disc"
    (is (approx (+ 80.0 (* Math/PI 4.0))
                (area (stroke/stroke-polygons [(sub [10 20 30 20] false)]
                                              (assoc opts :cap :round)))
                0.1))))

(deftest single-point-subpaths
  (let [pt (sub [10 10 10 10] false)]
    (is (empty? (stroke/stroke-polygons [pt] opts)))
    (is (approx 16.0 (area (stroke/stroke-polygons [pt] (assoc opts :cap :square))) 1e-6))
    (is (approx (* Math/PI 4.0) (area (stroke/stroke-polygons [pt] (assoc opts :cap :round))) 0.1))))

(deftest joins
  (let [corner (sub [10 30 20 30 20 20] false)
        a (fn [join & [limit]] (area (stroke/stroke-polygons
                                      [corner] (assoc opts :join join :miter-limit (or limit 4.0)))))]
    ;; two 10x4 rectangles overlap in a 2x2 square on the inner side
    (is (approx 76.0 (+ 40.0 40.0 -4.0) 1e-9))
    (testing "miter fills the outer corner square"
      (is (approx 80.0 (a :miter) 1e-6)))
    (testing "bevel cuts the outer corner diagonally"
      (is (approx 78.0 (a :bevel) 1e-6)))
    (testing "a miter beyond the limit falls back to bevel"
      (is (approx 78.0 (a :miter 1.0) 1e-6)))
    (testing "round adds a quarter disc"
      (is (approx (+ 76.0 (* 0.25 Math/PI 4.0)) (a :round) 0.1)))))

(deftest closed-subpaths-have-no-caps
  (let [sq (sub [10 10 30 10 30 30 10 30] true)
        polys (stroke/stroke-polygons [sq] (assoc opts :cap :round))]
    ;; frame between squares 8..32 and 12..28
    (is (approx (- (* 24 24) (* 16 16)) (area polys) 1e-6))))

(deftest reversal-puts-the-round-join-on-the-far-side
  (let [polys (stroke/stroke-polygons [(sub [10 20 30 20 10 20] false)]
                                      (assoc opts :join :round))]
    ;; segment rectangles coincide; round join adds a half disc past the turn
    (is (approx (+ 80.0 (* 0.5 Math/PI 4.0)) (area polys) 0.1))))
