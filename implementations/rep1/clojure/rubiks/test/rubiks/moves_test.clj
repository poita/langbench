(ns rubiks.moves-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [rubiks.moves :as moves]))

(def gen-token (gen/elements moves/tokens))
(def gen-tokens (gen/vector gen-token 0 40))

(deftest tokens-test
  (is (= 18 (count moves/tokens)))
  (is (= (set moves/tokens)
         (set (for [f "UDLRFB", s ["" "'" "2"]] (str f s)))))
  (is (= ["U" "U2" "U'"] (subvec moves/tokens 0 3)))
  (doseq [[i t] (map-indexed vector moves/tokens)]
    (is (= i (moves/token->id t)))
    (is (= t (moves/id->token i)))))

(deftest inverse-test
  (is (= "R'" (moves/inverse "R")))
  (is (= "R" (moves/inverse "R'")))
  (is (= "R2" (moves/inverse "R2")))
  (is (= ["F" "U'" "R'"] (moves/invert ["R" "U" "F'"]))))

(deftest parse-test
  (is (= [] (moves/parse "")))
  (is (= ["R" "U'" "F2"] (moves/parse "R U' F2")))
  (is (= "R U' F2" (moves/unparse ["R" "U'" "F2"])))
  (is (= "" (moves/unparse [])))
  (doseq [bad ["r" "R2'" "R'2" "X" "R  U2'"]]
    (is (thrown? clojure.lang.ExceptionInfo (moves/parse bad)) bad)))

(deftest simplify-test
  (is (= [] (moves/simplify ["R" "R'"])))
  (is (= ["R'"] (moves/simplify ["R" "R2"])))
  (is (= ["R2"] (moves/simplify ["R" "R"])))
  (is (= [] (moves/simplify ["R" "U" "U'" "R'"])))
  (is (= ["U" "D" "R"] (moves/simplify ["U" "D" "R"]))))

(defspec parse-unparse-roundtrip 100
  (prop/for-all [ts gen-tokens]
    (= ts (moves/parse (moves/unparse ts)))))

(defspec invert-is-involution 100
  (prop/for-all [ts gen-tokens]
    (= ts (moves/invert (moves/invert ts)))))
