(ns fulltext.analysis-test
  (:require [clojure.test :refer [deftest is testing]]
            [fulltext.analysis :as a]))

(defn- tokens
  "Raw token strings of `text`, cut out by the token spans."
  [^String text]
  (let [[^ints starts ^ints ends] (a/token-spans text)]
    (mapv #(subs text (aget starts %) (aget ends %)) (range (alength starts)))))

(deftest tokenising
  (doseq [[text expected]
          [["The cat sat." ["The" "cat" "sat"]]
           ["don't stop" ["don't" "stop"]]
           ["'quoted'" ["quoted"]]
           ["rock'n'roll" ["rock'n'roll"]]
           ["a''b" ["a" "b"]]
           ["well-known" ["well" "known"]]
           ["Version 1.2.3" ["Version" "1" "2" "3"]]
           ["X1 XY2Z" ["X1" "XY2Z"]]
           ["Don’t" ["Don’t"]]
           ["a × b ÷ c" ["a" "b" "c"]]
           ["" []]
           ["  ,, ." []]
           ["naïve Ωmega Привет" ["naïve" "Ωmega" "Привет"]]
           ["日本語 abc" ["abc"]]]]
    (is (= expected (tokens text)) text)))

(deftest spans-are-offsets-into-the-text
  (let [[starts ends] (a/token-spans "  ab, cd")]
    (is (= [2 6] (vec starts)))
    (is (= [4 8] (vec ends)))))

(deftest folding
  (is (= "dont" (a/fold "Don't")))
  (is (= "dont" (a/fold "Don’t")))
  (is (= "café" (a/fold "Café")))
  (is (= "cafÉ" (a/fold "CAFÉ")))
  (is (= "abc123" (a/fold "AbC123"))))

(deftest stop-words
  (is (= 33 (count a/stop-words)))
  (is (a/stop-word? "the"))
  (is (not (a/stop-word? "cat"))))

(deftest terms
  (is (= "run" (a/term "running")))
  (is (= "running2" (a/term "running2")))
  (is (= "caféing" (a/term "caféing")))
  (is (= "the" (a/term "the")))
  (let [t (a/memoizing-term-fn)]
    (is (= "connect" (t "connections") (t "connections")))))

(deftest analyze-pairs
  (is (= [{:text "dont" :term "dont"} {:text "stopping" :term "stop"}]
         (a/analyze "Don't Stopping"))))

(deftest atoms
  (testing "empty atoms"
    (is (nil? (a/atom-terms "")))
    (is (nil? (a/atom-terms "!!")))
    (is (nil? (a/atom-terms "The")))
    (is (= ["dont"] (a/atom-terms "Don't")) "dont is not a stop word"))
  (testing "stop words are kept inside multi-term atoms"
    (is (= ["to" "be" "or" "not" "to" "be"] (a/atom-terms "to be or not to be"))))
  (testing "hyphenated words give phrases"
    (is (= ["well" "known"] (a/atom-terms "well-known")))))
