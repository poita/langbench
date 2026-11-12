(ns langvm.types-test
  (:require [clojure.test :refer [deftest is testing]]
            [langvm.types :as t]))

(deftest unification
  (t/with-inference
    (let [a (t/fresh-var) b (t/fresh-var)]
      (testing "variables solve to types"
        (is (t/unify a :int))
        (is (= :int (t/prune a)))
        (is (not (t/unify a :str))))
      (testing "structural unification"
        (is (t/unify [:list b] [:list [:tuple :int :str]]))
        (is (= [:tuple :int :str] (t/zonk b))))
      (testing "mismatched forms fail"
        (is (not (t/unify [:list :int] [:map :int :int])))
        (is (not (t/unify [:tuple :int :int] [:tuple :int :int :int])))
        (is (not (t/unify [:named 3 [:int]] [:named 4 [:int]])))))))

(deftest occurs-check
  (t/with-inference
    (let [a (t/fresh-var)]
      (is (not (t/unify a [:list a])))
      (is (t/unify a a)))))

(deftest ground-and-owner
  (t/with-inference
    (binding [t/*owner* (atom [])]
      (let [a (t/fresh-var)]
        (is (= [a] @t/*owner*))
        (is (not (t/ground? [:list a])))
        (t/unify a :bool)
        (is (t/ground? [:list a]))))))

(deftest parameter-substitution
  (is (= [:fn [:int] [:list :str]]
         (t/subst-params [:fn [[:param 1]] [:list [:param 2]]] {1 :int 2 :str})))
  (is (t/mentions-param? [:map :int [:list [:param 7]]] 7))
  (is (not (t/mentions-param? [:list :int] 7))))

(deftest head-constructors
  (is (= [0 4 6 7 12] [(t/head-con :int) (t/head-con :str) (t/head-con [:list :int])
                       (t/head-con [:map :int :int]) (t/head-con [:named 4 []])]))
  (is (nil? (t/head-con [:tuple :int :int])))
  (is (nil? (t/head-con [:fn [] :unit]))))
