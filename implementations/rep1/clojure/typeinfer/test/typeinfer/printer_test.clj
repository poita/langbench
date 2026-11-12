(ns typeinfer.printer-test
  (:require [clojure.test :refer [deftest is testing]]
            [typeinfer.printer :as p]
            [typeinfer.types :as t]))

(def i t/int-type)
(def b t/bool-type)
(defn- fn-t [a r] (t/arrow a r))
(defn- show [ty] (p/type->string ty))

(deftest var-name-test
  (is (= ["'a" "'b" "'z" "'a1" "'b1" "'z1" "'a2"]
         (map p/var-name [0 1 25 26 27 51 52])))
  (is (= "'c315" (p/var-name (+ 2 (* 26 315))))))

(deftest parenthesisation-test
  (is (= "int -> int -> bool" (show (fn-t i (fn-t i b)))))
  (is (= "(int -> int) -> bool" (show (fn-t (fn-t i i) b))))
  (is (= "int * bool * unit" (show (t/tuple-of [i b t/unit-type]))))
  (is (= "(int -> int) * (int * int) * int"
         (show (t/tuple-of [(fn-t i i) (t/tuple-of [i i]) i]))))
  (is (= "int * int -> int * int" (show (fn-t (t/tuple-of [i i]) (t/tuple-of [i i])))))
  (is (= "int list list" (show (t/list-of (t/list-of i)))))
  (is (= "(int -> int) list" (show (t/list-of (fn-t i i)))))
  (is (= "(int * bool) list" (show (t/list-of (t/tuple-of [i b])))))
  (is (= "(int * int) * int" (show (t/tuple-of [(t/tuple-of [i i]) i])))))

(deftest variable-naming-test
  (testing "names follow first appearance, left to right"
    (let [x (t/fresh-var 1) y (t/fresh-var 1)]
      (is (= "'a -> 'b -> 'a" (show (fn-t x (fn-t y x)))))
      (is (= "'a * 'b -> 'b * 'a" (show (fn-t (t/tuple-of [x y]) (t/tuple-of [y x])))))))
  (testing "linked variables are followed"
    (let [x (t/fresh-var 1)]
      (t/unify x i)
      (is (= "int list" (show (t/list-of x)))))))
