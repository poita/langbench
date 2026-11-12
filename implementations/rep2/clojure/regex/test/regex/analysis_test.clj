(ns regex.analysis-test
  (:require [clojure.test :refer [deftest is]]
            [regex.analysis :as an]
            [regex.charset :as cs]
            [regex.parser :as p]))

(defn- ast [pattern] (:ast (p/parse pattern)))
(defn- firsts [pattern]
  (let [t (an/first-set (ast pattern))]
    (set (filter #(cs/member? t (int %)) (map char (range 32 127))))))

(deftest nullable
  (is (an/nullable? (ast "")))
  (is (an/nullable? (ast "a*")))
  (is (an/nullable? (ast "(a|)b?")))
  (is (an/nullable? (ast "^")))
  (is (an/nullable? (ast "a{0}")))
  (is (not (an/nullable? (ast "a+"))))
  (is (not (an/nullable? (ast "a|b")))))

(deftest first-sets
  (is (= #{\a} (firsts "abc")))
  (is (= #{\a \b} (firsts "a|b")))
  (is (= #{\a \b} (firsts "a*b")))
  (is (= #{\a} (firsts "^a")))
  (is (= #{\x} (firsts "(a{0}x)")))
  (is (= #{\0 \1 \2 \3 \4 \5 \6 \7 \8 \9} (firsts "\\d"))))

(deftest anchoring
  (is (an/start-anchored? (ast "^a")))
  (is (an/start-anchored? (ast "a*^b")))
  (is (an/start-anchored? (ast "^a|^b")))
  (is (an/start-anchored? (ast "(^a)+")))
  (is (not (an/start-anchored? (ast "^a|b"))))
  (is (not (an/start-anchored? (ast "(^a)*b"))))
  (is (not (an/start-anchored? (ast "a$")))))
