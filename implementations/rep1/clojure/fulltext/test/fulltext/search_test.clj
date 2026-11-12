(ns fulltext.search-test
  (:require [clojure.test :refer [deftest is testing]]
            [fulltext.core :as ft]
            [fulltext.report :as report]
            [fulltext.scoring :as scoring]))

(defn- approx= [a b] (< (Math/abs (- (double a) (double b))) 1e-6))

(def fox (ft/build-index {"note" "The quick brown fox jumps over the lazy dog."}))

(deftest worked-example-scores
  (is (approx= (Math/log (/ 4.0 3)) (scoring/idf 1 1)))
  (is (= [{:rank 1 :id "note" :snippet "The quick brown fox jumps over the lazy dog"}]
         (map #(dissoc % :score) (ft/search fox "fox"))))
  (is (approx= 0.287682 (:score (first (ft/search fox "fox")))))
  (is (approx= 0.575364 (:score (first (ft/search fox "quick brown")))))
  (is (approx= 0.287682 (:score (first (ft/search fox "\"lazy dog\"")))))
  (is (= [] (ft/search fox "cat"))))

(deftest ties-and-term-frequency
  (let [idx (ft/build-index {"copy1" "alpha beta gamma" "copy2" "alpha beta gamma"
                             "copy3" "alpha beta gamma" "other" "alpha alpha beta"})
        hits (ft/search idx "alpha")]
    (is (= ["other" "copy1" "copy2" "copy3"] (map :id hits)))
    (is (= ["0.1449" "0.1054" "0.1054" "0.1054"]
           (map (comp report/format-score :score) hits)))
    (is (= [1 2 3 4] (map :rank hits)))
    (testing "k limits the results"
      (is (= ["other" "copy1"] (map :id (ft/search idx "alpha" {:k 2})))))))

(deftest boolean-semantics
  (let [idx (ft/build-index {"1" "cat dog" "2" "cat" "3" "bird"})]
    (is (= ["1"] (map :id (ft/search idx "cat AND dog"))))
    (is (= ["2"] (map :id (ft/search idx "cat NOT dog"))))
    (is (= #{"1" "2" "3"} (set (map :id (ft/search idx "cat OR bird OR NOT cat")))))
    (testing "queries with no positive atoms score zero"
      (let [hits (ft/search idx "NOT cat")]
        (is (= ["3"] (map :id hits)))
        (is (= 0.0 (:score (first hits))))))
    (testing "the empty query matches nothing"
      (is (= [] (ft/search idx "the"))))))

(deftest snippets-pick-the-densest-window
  (let [filler (apply str (repeat 40 "xx "))
        idx (ft/build-index {"d" (str "needle " filler "\n\n needle   haystack\tneedle " filler)})]
    (is (= (str (apply str (repeat 27 "xx ")) "needle haystack needle")
           (:snippet (first (ft/search idx "needle")))))))

(deftest empty-documents
  (let [idx (ft/build-index {"e" "" "f" "word"})]
    (is (= [{:rank 1 :id "f" :snippet "word"}]
           (map #(dissoc % :score) (ft/search idx "word"))))
    (is (= [] (ft/search idx "word NOT word")))
    (is (= "" (:snippet (first (ft/search idx "NOT word")))))))
