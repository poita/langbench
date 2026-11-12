(ns svgraster.color-test
  (:require [clojure.test :refer [deftest is]]
            [svgraster.color :as c]))

(deftest keyword-table
  (is (= 147 (count c/named-colors)))
  (is (= [255 0 0] (c/parse-color "red")))
  (is (= [255 0 0] (c/parse-color "RED")))
  (is (= [154 205 50] (c/parse-color "yellowgreen")))
  (is (= [128 128 128] (c/parse-color "grey")))
  (is (nil? (c/parse-color "notacolor"))))

(deftest hex
  (is (= [255 51 153] (c/parse-color "#f39")))
  (is (= [255 51 153] (c/parse-color "#FF3399")))
  (is (nil? (c/parse-color "#ff33")))
  (is (nil? (c/parse-color "#gggggg"))))

(deftest rgb-function
  (is (= [10 20 30] (c/parse-color "rgb(10, 20, 30)")))
  (is (= [10 20 30] (c/parse-color "rgb(10 20 30)")))
  (is (= [255 0 128] (c/parse-color "rgb(300,-5,127.5)")) "clamped and rounded half up")
  (is (= [255 128 0] (c/parse-color "rgb(100%, 50%, 0%)")) "127.5 rounds up")
  (is (= [255 0 0] (c/parse-color "RGB(200%,0%,0%)")))
  (is (nil? (c/parse-color "rgb(1,2)"))))

(deftest special-values
  (is (= :none (c/parse-color "none")))
  (is (= :current (c/parse-color "currentColor")))
  (is (= :current (c/parse-color "CURRENTCOLOR"))))
