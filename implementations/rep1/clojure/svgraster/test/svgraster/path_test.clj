(ns svgraster.path-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [svgraster.matrix :as m]
            [svgraster.path :as path]))

(defn- near? [a b] (< (Math/abs (- (double a) (double b))) 1e-9))

(deftest absolute-and-relative
  (is (= [[:M 1.0 2.0] [:L 3.0 2.0] [:L 3.0 5.0] [:Z]]
         (path/parse-path-data "M1 2 H3 V5 z")))
  (is (= [[:M 1.0 1.0] [:L 2.0 3.0] [:L 5.0 3.0]]
         (path/parse-path-data "m1 1 l1 2 h3"))))

(deftest implicit-repeats
  (is (= [[:M 0.0 0.0] [:L 1.0 1.0] [:L 2.0 2.0]] (path/parse-path-data "M0,0 1,1 2,2")))
  (is (= [[:M 1.0 1.0] [:L 2.0 2.0] [:L 3.0 3.0]] (path/parse-path-data "m1 1 1 1 1 1"))))

(deftest compact-numbers
  (is (= [[:M 0.5 -0.5] [:L 0.25 0.5]] (path/parse-path-data "M.5-.5L.25.5"))))

(deftest arc-flags-are-single-characters
  (let [segs (path/parse-path-data "M0 0 a5 5 0 0110 10")]
    (is (= [10.0 10.0] (vec (take-last 2 (last segs)))))))

(deftest parsing-stops-at-the-first-bad-token
  (is (= [[:M 0.0 0.0] [:L 5.0 5.0]] (path/parse-path-data "M0 0 L5 5 bogus L9 9")))
  (is (= [[:M 0.0 0.0] [:L 5.0 5.0]] (path/parse-path-data "M0 0 L5 5 L7")))
  (is (= [[:M 0.0 0.0] [:L 5.0 0.0] [:Z]] (path/parse-path-data "M0 0 L5 0 Z 5 5")))
  (is (= [] (path/parse-path-data "")))
  (is (= [] (path/parse-path-data "L1 1"))))

(deftest drawing-after-close-starts-at-the-subpath-start
  (is (= [[:M 1.0 1.0] [:L 2.0 1.0] [:Z] [:M 1.0 1.0] [:L 1.0 4.0]]
         (path/parse-path-data "M1 1 L2 1 Z L1 4"))))

(deftest smooth-and-quadratic
  (testing "S reflects the previous cubic control point"
    (let [[_ _ [_ x1 y1]] (path/parse-path-data "M0 0 C0 10 10 10 10 0 S 20 -10 20 0")]
      (is (= [10.0 -10.0] [x1 y1]))))
  (testing "S without a previous cubic uses the current point"
    (let [[_ [_ x1 y1]] (path/parse-path-data "M5 5 S 7 7 9 9")]
      (is (= [5.0 5.0] [x1 y1]))))
  (testing "Q becomes the equivalent cubic"
    (let [[_ [_ x1 y1 x2 y2 x y]] (path/parse-path-data "M0 0 Q 3 6 6 0")]
      (is (every? true? (map near? [2 4 4 4 6 0] [x1 y1 x2 y2 x y])))))
  (testing "T reflects the previous quadratic control point"
    (let [[_ _ [_ x1 y1]] (path/parse-path-data "M0 0 Q 3 6 6 0 T 12 0")]
      (is (near? 8 x1))
      (is (near? -4 y1)))))

(deftest arcs
  (is (= [] (path/arc->segments 1 1 5 5 0 false true 1 1)) "same end points: dropped")
  (is (= [[:L 9.0 9.0]] (path/arc->segments 0 0 0 5 0 false true 9 9)) "zero radius: line")
  (let [segs (path/arc->segments 10 0 10 10 0 false true 0 10)]
    (testing "a quarter circle ends exactly at the end point"
      (is (= [0.0 10.0] (vec (take-last 2 (last segs))))))
    (testing "sweep=1 turns clockwise on screen: the arc bulges to +x,+y"
      (let [[_ _ _ _ _ x y] (first segs)]
        (is (and (> x 5.0) (> y 0.0)))))))

(defspec arc-points-lie-on-a-circle-through-the-end-points 100
  (prop/for-all [r (gen/double* {:min 5.0 :max 50.0 :NaN? false :infinite? false})
                 a1 (gen/double* {:min 0.0 :max 6.0 :NaN? false :infinite? false})
                 span (gen/double* {:min 0.2 :max 3.0 :NaN? false :infinite? false})
                 large? gen/boolean
                 sweep? gen/boolean]
    ;; With rx = ry = r every arc between two points of the circle of radius r
    ;; about the origin runs along that circle or its mirror image about the
    ;; chord, so every segment end point is at distance r from one of the two
    ;; possible centres.
    (let [x1 (* r (Math/cos a1)) y1 (* r (Math/sin a1))
          x2 (* r (Math/cos (+ a1 span))) y2 (* r (Math/sin (+ a1 span)))
          mx (/ (+ x1 x2) 2.0) my (/ (+ y1 y2) 2.0)
          cx2 (- (* 2.0 mx) 0.0) cy2 (- (* 2.0 my) 0.0) ; mirror image of the origin
          segs (path/arc->segments x1 y1 r r 0.0 large? sweep? x2 y2)
          ok? (fn [[x y]]
                (or (< (Math/abs (- (Math/hypot x y) r)) 1e-6)
                    (< (Math/abs (- (Math/hypot (- x cx2) (- y cy2)) r)) 1e-6)))]
      (and (seq segs) (every? #(ok? (vec (take-last 2 %))) segs)))))

(deftest shapes
  (is (= [[:M 1.0 2.0] [:L 4.0 2.0] [:L 4.0 6.0] [:L 1.0 6.0] [:Z]]
         (path/rect-path 1.0 2.0 3.0 4.0 nil nil)))
  (is (nil? (path/rect-path 0.0 0.0 0.0 4.0 nil nil)))
  (testing "a single radius applies to both axes, clamped to half the size"
    (let [p (path/rect-path 0.0 0.0 10.0 10.0 20.0 nil)]
      (is (= [:M 5.0 0.0] (first p)))))
  (is (nil? (path/ellipse-path 0.0 0.0 0.0 5.0)))
  (is (= :Z (first (last (path/ellipse-path 5.0 5.0 3.0 2.0)))))
  (is (= [[:M 0.0 0.0] [:L 1.0 1.0] [:L 2.0 0.0] [:Z]]
         (path/polyline-path [0.0 0.0 1.0 1.0 2.0 0.0] true)))
  (is (nil? (path/polyline-path [] false))))

(deftest flattening
  (testing "lines are kept as they are"
    (let [[sp] (path/flatten-path [[:M 0.0 0.0] [:L 4.0 0.0] [:L 4.0 4.0] [:Z]] m/identity-matrix 0.01)]
      (is (= [0.0 0.0 4.0 0.0 4.0 4.0] (vec (:points sp))))
      (is (:closed? sp))))
  (testing "a lone M is not a subpath, but M Z is"
    (is (= [] (path/flatten-path [[:M 1.0 1.0]] m/identity-matrix 0.01)))
    (is (= 1 (count (path/flatten-path [[:M 1.0 1.0] [:Z]] m/identity-matrix 0.01)))))
  (testing "the matrix is applied before flattening"
    (let [[sp] (path/flatten-path [[:M 1.0 1.0] [:L 2.0 1.0]] (m/scale 3.0 2.0) 0.01)]
      (is (= [3.0 2.0 6.0 2.0] (vec (:points sp)))))))

(defspec flattened-cubic-stays-within-tolerance 50
  (prop/for-all [c (gen/vector (gen/double* {:min -100.0 :max 100.0 :NaN? false :infinite? false}) 8)]
    (let [[x0 y0 x1 y1 x2 y2 x3 y3] c
          [sp] (path/flatten-path [[:M x0 y0] [:C x1 y1 x2 y2 x3 y3]] m/identity-matrix 0.01)
          ^doubles pts (:points sp)
          n (quot (alength pts) 2)
          seg-dist (fn [px py ax ay bx by]
                     (let [dx (- bx ax) dy (- by ay)
                           l2 (+ (* dx dx) (* dy dy))
                           t (if (zero? l2) 0.0 (max 0.0 (min 1.0 (/ (+ (* (- px ax) dx) (* (- py ay) dy)) l2))))
                           qx (+ ax (* t dx)) qy (+ ay (* t dy))]
                       (Math/hypot (- px qx) (- py qy))))
          dist (fn [px py]
                 (reduce min (for [i (range (dec n))]
                               (seg-dist px py (aget pts (* 2 i)) (aget pts (inc (* 2 i)))
                                         (aget pts (* 2 (inc i))) (aget pts (inc (* 2 (inc i))))))))]
      (every? (fn [i]
                (let [t (/ i 200.0) u (- 1.0 t)
                      b0 (* u u u) b1 (* 3 u u t) b2 (* 3 u t t) b3 (* t t t)]
                  (<= (dist (+ (* b0 x0) (* b1 x1) (* b2 x2) (* b3 x3))
                            (+ (* b0 y0) (* b1 y1) (* b2 y2) (* b3 y3)))
                      0.0101)))
              (range 201)))))
