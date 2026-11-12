(ns fulltext.index-test
  (:require [clojure.test :refer [deftest is]]
            [fulltext.index :as idx]))

(def sample
  (idx/build-index {"b" "The cat sat. The cat ran."
                    "a" "Dogs bark"
                    "c" ""}))

(deftest documents-are-ordered-by-id
  (is (= ["a" "b" "c"] (map :id (:docs sample)))))

(deftest lengths-and-stats
  (is (= [2 6 0] (map :length (:docs sample))))
  (is (= {:documents 3 :tokens 8 :terms 6 :avgdl (/ 8.0 3)} (idx/stats sample))))

(deftest postings-hold-sorted-positions
  (let [p (idx/postings sample "cat")]
    (is (= [1] (vec (:docs p))) "only doc index 1 (id b)")
    (is (= [[1 4]] (map vec (:positions p)))))
  (let [p (idx/postings sample "the")]
    (is (= [[0 3]] (map vec (:positions p)))))
  (is (nil? (idx/postings sample "missing"))))

(deftest stemmed-terms
  (is (some? (idx/postings sample "dog")))
  (is (nil? (idx/postings sample "dogs"))))

(deftest empty-corpus
  (is (= {:documents 0 :tokens 0 :terms 0 :avgdl 0.0}
         (idx/stats (idx/build-index {})))))
