(ns chip8.display-test
  (:require [chip8.core :as core]
            [chip8.display :as display]
            [chip8.test-util :refer [reg run-ops v]]
            [clojure.test :refer [deftest is testing]]))

(def wrap-ops [0x6a3e 0x6b1e 0x6000 0xf029 0xdab5])

(deftest draw-wraps-both-axes
  (let [rows (display/render (run-ops wrap-ops))]
    (is (= 32 (count rows)))
    (is (= ".#............................................................#." (rows 0)))
    (is (= "##............................................................##" (rows 2)))
    (is (= "##............................................................##" (rows 30)))
    (is (= ".#............................................................#." (rows 31)))
    (is (= 0 (v (run-ops wrap-ops) 0xF)))))

(deftest draw-twice-erases-and-flags
  (let [m (run-ops (conj wrap-ops 0xdab5))]
    (is (every? #(= (apply str (repeat 64 \.)) %) (display/render m)))
    (is (= 1 (v m 0xF)))))

(deftest origin-is-reduced
  (let [a (display/render (run-ops [0x6000 0xf029 0x6a05 0x6b03 0xdab5]))
        b (display/render (run-ops [0x6000 0xf029 0x6a45 0x6b23 0xdab5]))]
    (is (= a b))))

(deftest zero-rows-draws-nothing
  (let [m (run-ops [0x6f01 0xd000])]
    (is (= 0 (v m 0xF)))
    (is (every? #(not (re-find #"#" %)) (display/render m)))))

(deftest clear-screen
  (let [m (run-ops [0xf029 0xd005 0x00e0])]
    (is (not-any? #(re-find #"#" %) (display/render m)))))
