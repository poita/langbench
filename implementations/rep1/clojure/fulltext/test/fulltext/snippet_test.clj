(ns fulltext.snippet-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [fulltext.snippet :as s]))

(defn- brute-force-window
  "Reference implementation straight from the definition."
  [len occurrences]
  (let [w s/window-size
        window (fn [st] (let [end (dec (min (+ st w) len))]
                          (for [[ai [n starts]] (map-indexed vector occurrences)
                                p starts
                                :when (and (>= p st) (<= (+ p n -1) end))]
                            [ai p])))
        score (fn [st] (let [in (window st)]
                         [(count (distinct (map first in))) (count in)]))]
    (reduce (fn [best st]
              (if (pos? (compare (score st) (score best))) st best))
            0 (range 0 (inc (max 0 (- len w)))))))

(def gen-case
  (gen/let [len (gen/choose 0 120)
            atoms (gen/vector
                   (gen/let [n (gen/choose 1 35)
                             ps (gen/set (gen/choose 0 (max 0 (- len n))) {:max-elements 12})]
                     [n (int-array (sort (filter #(<= (+ % n) len) ps)))])
                   0 4)]
    [len (filter #(pos? (alength ^ints (second %))) atoms)]))

(defspec best-window-matches-brute-force 500
  (prop/for-all [[len atoms] gen-case]
    (= (brute-force-window len atoms) (s/best-window len atoms))))

(deftest best-window-examples
  (is (= 0 (s/best-window 10 [])) "no occurrences")
  (is (= 0 (s/best-window 10 [[1 (int-array [5])]])) "short document")
  (is (= 63 (s/best-window 100 [[1 (int-array [5 90 91 92])]]))
      "the earliest window holding the most occurrences")
  (is (= 0 (s/best-window 100 [[31 (int-array [10])]])) "atoms wider than W never fit")
  (is (= 70 (s/best-window 100 [[1 (int-array [10 99])] [1 (int-array [75])]]))
      "more distinct atoms beat more occurrences"))

(deftest whitespace-collapsing
  (is (= "a b c" (s/collapse-whitespace "a \t\n b \u000B c")))
  (is (= "x" (s/collapse-whitespace "x"))))

(deftest extraction
  (let [text "  Hello,\n\n  world! Foo."
        starts (int-array [2 12 19])
        ends (int-array [7 17 22])]
    (is (= "Hello, world! Foo" (s/extract text starts ends 0)))
    (is (= "" (s/extract "  !! " (int-array 0) (int-array 0) 0)))))
