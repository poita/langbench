(ns svgraster.raster-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [svgraster.raster :as raster]))

(defn- rect [x0 y0 x1 y1] (double-array [x0 y0 x1 y0 x1 y1 x0 y1]))

(defn- alpha-at [canvas x y]
  (aget ^doubles (:data canvas) (+ 3 (* 4 (+ x (* y (:width canvas)))))))

(deftest spec-example-fractional-edge
  (let [c (raster/new-canvas 8 4)]
    (raster/fill-polygons! c [(rect 1 1 4.5 3)] :nonzero [0.0 0.0 1.0] 1.0)
    (is (= [0.0 1.0 1.0 1.0 0.5 0.0 0.0 0.0] (mapv #(alpha-at c % 1) (range 8))))
    (is (= [0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0] (mapv #(alpha-at c % 0) (range 8))))
    (let [bytes (raster/->rgb-bytes c)
          px (fn [x y] (mapv #(bit-and 255 (aget bytes (+ (* 3 (+ x (* 8 y))) %))) (range 3)))]
      (is (= [255 255 255] (px 0 1)))
      (is (= [0 0 255] (px 2 1)))
      (is (= [128 128 255] (px 4 1))))))

(defspec rect-coverage-is-its-area 100
  (prop/for-all [x0 (gen/double* {:min 0.0 :max 15.0 :NaN? false :infinite? false})
                 y0 (gen/double* {:min 0.0 :max 15.0 :NaN? false :infinite? false})
                 w (gen/double* {:min 0.1 :max 15.0 :NaN? false :infinite? false})
                 h (gen/double* {:min 0.1 :max 15.0 :NaN? false :infinite? false})]
    (let [c (raster/new-canvas 32 32)]
      (raster/fill-polygons! c [(rect x0 y0 (+ x0 w) (+ y0 h))] :nonzero [0.0 0.0 0.0] 1.0)
      (let [total (reduce + (for [y (range 32) x (range 32)] (alpha-at c x y)))]
        ;; vertical edges are exact; horizontal ones are quantised to 1/64
        (< (Math/abs (- total (* w h))) (* 2.0 (+ w h) (/ 1.0 64)))))))

(deftest winding-rules
  (let [star (double-array [10 0 16 18 0 7 20 7 4 18])
        count-at (fn [rule x y]
                   (let [c (raster/new-canvas 20 20)]
                     (raster/fill-polygons! c [star] rule [0.0 0.0 0.0] 1.0)
                     (alpha-at c x y)))]
    (is (= 1.0 (count-at :nonzero 10 9)) "centre pentagon is filled with nonzero")
    (is (= 0.0 (count-at :evenodd 10 9)) "and empty with evenodd")
    (is (= 1.0 (count-at :evenodd 10 3)) "the tips are filled either way")))

(deftest union-of-overlapping-pieces
  (let [c (raster/new-canvas 10 10)]
    (raster/fill-polygons! c [(rect 0 0 6 10) (rect 4 0 10 10)] :nonzero [0.0 0.0 0.0] 1.0)
    (is (= 1.0 (alpha-at c 5 5)) "overlap is not double counted")))

(deftest clipping-and-degenerate-input
  (let [c (raster/new-canvas 4 4)]
    (raster/fill-polygons! c [(rect -100 -100 100 100)] :nonzero [0.0 0.0 0.0] 1.0)
    (is (every? #(== 1.0 %) (for [y (range 4) x (range 4)] (alpha-at c x y)))))
  (let [c (raster/new-canvas 4 4)]
    (raster/fill-polygons! c [(double-array [1 1 3 1]) (rect 10 10 20 20)
                              (double-array [##NaN 0 1 1 2 2])]
                           :nonzero [0.0 0.0 0.0] 1.0)
    (is (every? zero? (for [y (range 4) x (range 4)] (alpha-at c x y))))))

(deftest compositing
  (testing "source-over with paint opacity"
    (let [c (raster/new-canvas 1 1)]
      (raster/fill-polygons! c [(rect 0 0 1 1)] :nonzero [1.0 0.0 0.0] 0.5)
      (raster/fill-polygons! c [(rect 0 0 1 1)] :nonzero [0.0 0.0 1.0] 0.5)
      (let [d ^doubles (:data c)]
        (is (= [0.25 0.0 0.5 0.75] (vec d))))))
  (testing "group opacity"
    (let [dst (raster/new-canvas 1 1)
          layer (raster/new-canvas 1 1)]
      (raster/fill-polygons! layer [(rect 0 0 1 1)] :nonzero [0.0 0.0 1.0] 1.0)
      (raster/composite-layer! dst layer 0.5)
      (is (= [0.0 0.0 0.5 0.5] (vec ^doubles (:data dst)))))))

(deftest orientation
  (let [cw (rect 0 0 2 2)
        ccw (double-array [0 0 0 2 2 2 2 0])]
    (is (pos? (raster/signed-area (raster/orient-positive cw))))
    (is (pos? (raster/signed-area (raster/orient-positive ccw))))))

(deftest ppm-output
  (let [c (raster/new-canvas 2 1)
        bytes (raster/->ppm c)
        header (String. bytes 0 11 "US-ASCII")]
    (is (= "P6\n2 1\n255\n" header))
    (is (= (+ 11 6) (alength bytes)))
    (is (every? #(= -1 %) (drop 11 bytes)) "an empty canvas is white")))
