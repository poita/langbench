(ns typeinfer.types-test
  (:require [clojure.test :refer [deftest is testing]]
            [typeinfer.printer :as printer]
            [typeinfer.types :as t]))

(defn- kind-of [f]
  (try (f) nil (catch clojure.lang.ExceptionInfo e (:kind (ex-data e)))))

(deftest unify-test
  (testing "variables bind to types"
    (let [a (t/fresh-var 1)]
      (t/unify a (t/list-of t/int-type))
      (is (= "int list" (printer/type->string a)))))
  (testing "constructor mismatch"
    (is (= :unify (kind-of #(t/unify t/int-type t/bool-type))))
    (is (= :unify (kind-of #(t/unify t/int-type (t/arrow t/int-type t/int-type)))))
    (is (= :unify (kind-of #(t/unify (t/tuple-of [t/int-type t/int-type])
                                     (t/tuple-of [t/int-type t/int-type t/int-type]))))))
  (testing "occurs check"
    (let [a (t/fresh-var 1)]
      (is (= :occurs (kind-of #(t/unify a (t/arrow a t/int-type)))))))
  (testing "components are unified left to right"
    (let [a (t/fresh-var 1)]
      (is (= :occurs
             (kind-of #(t/unify (t/tuple-of [a t/int-type])
                                (t/tuple-of [(t/list-of a) t/bool-type])))))))
  (testing "unifying a variable with itself is a no-op"
    (let [a (t/fresh-var 1)]
      (t/unify a a)
      (is (= "'a" (printer/type->string a))))))

(deftest levels-test
  (testing "binding lowers the levels of the variables reached"
    (let [outer (t/fresh-var 1)
          inner (t/fresh-var 3)]
      (t/unify outer (t/list-of inner))
      (is (= 1 (t/level inner)))))
  (testing "generalisation only quantifies variables deeper than the level"
    (let [shallow (t/fresh-var 1)
          deep (t/fresh-var 2)
          ty (t/arrow shallow deep)]
      (t/generalize! ty 1)
      (is (= 1 (t/level shallow)))
      (is (= t/generic (t/level deep))))))

(deftest instantiate-test
  (let [a (t/generic-var)
        scheme (t/arrow a (t/list-of a))
        i1 (t/instantiate scheme 1)
        i2 (t/instantiate scheme 1)]
    (is (= "'a -> 'a list" (printer/type->string i1)))
    (testing "each instance is independent"
      (t/unify (t/arrow t/int-type (t/list-of t/int-type)) i1)
      (is (= "int -> int list" (printer/type->string i1)))
      (is (= "'a -> 'a list" (printer/type->string i2)))))
  (testing "sub-terms without generic variables are shared"
    (let [mono (t/list-of t/int-type)
          scheme (t/arrow (t/generic-var) mono)
          inst (t/instantiate scheme 1)]
      (is (identical? mono (second (t/args inst))))))
  (testing "a closed type is returned as is"
    (let [ty (t/arrow t/int-type t/bool-type)]
      (is (identical? ty (t/instantiate ty 1)))))
  (testing "sharing is preserved: a 2^40-leaf type costs 40 nodes"
    (let [g (t/generic-var)
          tower (nth (iterate #(t/tuple-of [% %]) g) 40)
          inst (t/instantiate tower 1)
          [l r] (t/args inst)]
      (is (identical? l r)))))

(deftest shared-dag-unification-test
  (testing "unifying two big shared types does not expand them"
    (let [mk (fn [] (nth (iterate #(t/tuple-of [% %]) (t/fresh-var 1)) 200))
          a (mk) b (mk)]
      (t/unify a b)
      (is (nil? (kind-of #(t/unify a b)))))))
