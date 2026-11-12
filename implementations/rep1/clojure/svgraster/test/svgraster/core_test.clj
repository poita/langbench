(ns svgraster.core-test
  (:require [clojure.java.io :as io]
            [clojure.test :refer [deftest is testing]]
            [svgraster.core :as svg])
  (:import (java.nio.file Files)))

(defn- svg [attrs body] (str "<svg xmlns='http://www.w3.org/2000/svg' " attrs ">" body "</svg>"))

(defn- px
  "RGB of pixel (x, y) of a rendered image as a vector of ints."
  [{:keys [width ^bytes pixels]} x y]
  (mapv #(bit-and 255 (aget pixels (+ (* 3 (+ x (* width y))) %))) (range 3)))

(defn- close? [a b tol] (every? true? (map #(<= (Math/abs (- (long %1) (long %2))) tol) a b)))

(defn- render [attrs body w h] (svg/render-svg (svg attrs body) w h))

(deftest example-rectangle
  (let [img (render "viewBox='0 0 8 4'" "<rect x='1' y='1' width='3.5' height='2' fill='#0000ff'/>" 8 4)]
    (is (= [255 255 255] (px img 0 1)))
    (is (= [0 0 255] (px img 1 1)))
    (is (= [128 128 255] (px img 4 1)))
    (is (= [255 255 255] (px img 5 3)))))

(deftest example-stroke-and-transform
  (let [img (render "viewBox='0 0 10 10'"
                    "<g transform='scale(2)'><rect x='1' y='1' width='3' height='3' fill='none' stroke='black'/></g>"
                    40 40)]
    (is (= [0 0 0] (px img 4 20)))
    (is (= [0 0 0] (px img 11 20)))
    (is (= [255 255 255] (px img 12 20)))
    (is (= [255 255 255] (px img 3 20)))))

(deftest even-odd-star
  (let [star "<path d='M10 0 L16 18 L0 7 L20 7 L4 18 Z' fill='#8e44ad' fill-rule='%s'/>"]
    (is (= [142 68 173] (px (render "viewBox='0 0 20 20'" (format star "nonzero") 20 20) 10 9)))
    (is (= [255 255 255] (px (render "viewBox='0 0 20 20'" (format star "evenodd") 20 20) 10 9)))
    (testing "values are case sensitive: EVENODD is the initial value"
      (is (= [142 68 173] (px (render "viewBox='0 0 20 20'" (format star "EVENODD") 20 20) 10 9))))))

(deftest group-opacity-is-not-per-shape-opacity
  (let [group (render "viewBox='0 0 50 40'"
                      "<g opacity='0.5'><circle cx='20' cy='20' r='15' fill='red'/><circle cx='30' cy='20' r='15' fill='blue'/></g>"
                      50 40)
        each (render "viewBox='0 0 50 40'"
                     "<circle cx='20' cy='20' r='15' fill='red' opacity='0.5'/><circle cx='30' cy='20' r='15' fill='blue' opacity='0.5'/>"
                     50 40)]
    (is (close? [128 128 255] (px group 25 20) 1))
    (is (close? [128 64 191] (px each 25 20) 1))))

(deftest display-and-precedence
  (testing "the style attribute beats the presentation attribute"
    (is (= [0 0 0] (px (render "viewBox='0 0 2 2'" "<rect width='2' height='2' display='none' style='display:inline'/>" 2 2) 1 1))))
  (testing "display:none hides descendants even when they say otherwise"
    (is (= [255 255 255]
           (px (render "viewBox='0 0 2 2'" "<g display='none'><rect width='2' height='2' display='inline'/></g>" 2 2) 1 1)))))

(deftest inheritance-and-current-color
  (let [img (render "viewBox='0 0 4 2' color='#00ff00' fill='currentColor'"
                    "<g style='fill:#ff0000'><rect width='2' height='2'/><rect x='2' width='2' height='2' fill='currentColor'/></g>"
                    4 2)]
    (is (= [255 0 0] (px img 0 0)))
    (is (= [0 255 0] (px img 3 0)))))

(deftest use-and-defs
  (let [body "<defs><rect id='r' width='2' height='2' fill='#123456'/></defs>
              <use href='#r' x='2' transform='translate(0 2)'/>
              <use href='#missing'/>"
        img (render "viewBox='0 0 4 4'" body 4 4)]
    (is (= [255 255 255] (px img 0 0)) "defs content is not drawn directly")
    (is (= [0x12 0x34 0x56] (px img 3 3)))
    (is (= [255 255 255] (px img 1 3))))
  (testing "properties are inherited into the referenced element"
    (let [img (render "viewBox='0 0 2 2'" "<defs><rect id='r' width='2' height='2'/></defs><use href='#r' fill='#ff0000'/>" 2 2)]
      (is (= [255 0 0] (px img 1 1))))))

(deftest viewport-selection
  (testing "viewBox is stretched to the output size"
    (let [img (render "viewBox='0 0 2 1'" "<rect width='1' height='1' fill='black'/>" 8 8)]
      (is (= [0 0 0] (px img 3 7)))
      (is (= [255 255 255] (px img 4 7)))))
  (testing "width/height are used without a viewBox"
    (let [img (render "width='4' height='4'" "<rect width='2' height='4' fill='black'/>" 8 8)]
      (is (= [0 0 0] (px img 3 0)))
      (is (= [255 255 255] (px img 4 0)))))
  (testing "otherwise the output size is the user space"
    (let [img (render "" "<rect width='4' height='8' fill='black'/>" 8 8)]
      (is (= [0 0 0] (px img 3 0)))
      (is (= [255 255 255] (px img 4 0))))))

(deftest ppm-bytes
  (let [bytes (svg/image->ppm (render "" "" 3 2))]
    (is (= "P6\n3 2\n255\n" (String. bytes 0 11 "US-ASCII")))
    (is (= (+ 11 18) (alength bytes)))))

(deftest render-list
  (is (= [{:name "a.svg" :width 10 :height 20} {:name "b.svg" :width 5 :height 5}]
         (svg/parse-render-list "# comment\r\n\r\n   \na.svg 10 20\r\n  b.svg\t5   5  \n  # another\n"))))

(deftest render-directory-writes-files
  (let [tmp (Files/createTempDirectory "svgraster" (into-array java.nio.file.attribute.FileAttribute []))
        in (io/file (.toFile tmp) "in")
        out (io/file (.toFile tmp) "out" "nested")]
    (try
      (.mkdirs in)
      (spit (io/file in "render.txt") "# list\nsq.svg 4 4\nother.svg 2 3\n")
      (spit (io/file in "sq.svg") (svg "viewBox='0 0 4 4'" "<rect width='4' height='4' fill='#ff0000'/>"))
      (spit (io/file in "other.svg") (svg "" ""))
      (let [written (svg/render-directory (str in) (str out))]
        (is (= 2 (count written)))
        (let [bytes (Files/readAllBytes (.toPath (io/file out "sq.ppm")))]
          (is (= (+ 11 48) (alength bytes)))
          (is (= [-1 0 0] (mapv #(aget bytes (+ 11 %)) (range 3)))))
        (is (.exists (io/file out "other.ppm"))))
      (testing "a broken file is reported and the others are still rendered"
        (spit (io/file in "render.txt") "bad.svg 2 2\nsq.svg 4 4\n")
        (spit (io/file in "bad.svg") "not xml")
        (let [errors (atom [])
              written (svg/render-directory (str in) (str out) (fn [entry _] (swap! errors conj (:name entry))))]
          (is (= ["bad.svg"] @errors))
          (is (= 1 (count written)))))
      (finally
        (doseq [f (reverse (file-seq (.toFile tmp)))] (.delete ^java.io.File f))))))
