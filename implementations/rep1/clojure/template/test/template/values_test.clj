(ns template.values-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [template.errors :as err]
            [template.json :as json]
            [template.values :as v]))

(deftest float-formatting
  (doseq [[d s] [[3.0 "3.0"] [0.5 "0.5"] [1000000000000000.0 "1000000000000000.0"]
                 [0.0001 "0.0001"] [0.30000000000000004 "0.30000000000000004"]
                 [1e16 "1e+16"] [1e-5 "1e-05"] [1.5e300 "1.5e+300"]
                 [0.0 "0.0"] [-0.0 "-0.0"] [-2.5 "-2.5"] [123456.789 "123456.789"]
                 [1.5e-7 "1.5e-07"] [1.2345e20 "1.2345e+20"]]]
    (is (= s (v/format-float d)) (str d))))

(defspec float-format-round-trips 500
  (prop/for-all [d (gen/double* {:NaN? false :infinite? false})]
    (= d (Double/parseDouble (v/format-float d)))))

(deftest printing
  (is (= "True" (v/to-str true)))
  (is (= "None" (v/to-str nil)))
  (is (= "-5" (v/to-str -5)))
  (is (= "[1, 'a', True, None, 1.5, \"it's\", {'k': [2.0]}]"
         (v/to-str (json/parse "[1, \"a\", true, null, 1.5, \"it's\", {\"k\": [2.0]}]"))))
  (is (= "['a\\'b\"c', 'x\\ny']" (v/to-str ["a'b\"c" "x\ny"])))
  (is (= "{}" (v/to-str (json/parse "{}"))))
  (is (= :undefined (err/error-kind (try (v/to-str v/undefined) (catch Exception e e))))))

(deftest truthiness
  (doseq [x [false nil 0 0.0 "" [] (json/parse "{}")]] (is (not (v/truthy? x)) (pr-str x)))
  (doseq [x [true 1 -1 0.1 "0" [nil] (json/parse "{\"a\":1}")]] (is (v/truthy? x) (pr-str x)))
  (is (thrown? clojure.lang.ExceptionInfo (v/truthy? v/undefined))))

(deftest equality
  (is (v/values-equal? 1 1.0))
  (is (v/values-equal? true 1))
  (is (not (v/values-equal? 1 "1")))
  (is (not (v/values-equal? nil 0)))
  (is (v/values-equal? [1 "a"] [1.0 "a"]))
  (is (v/values-equal? (json/parse "{\"a\":1,\"b\":2}") (json/parse "{\"b\":2,\"a\":1}"))))

(deftest sequence-views
  (is (= ["a" "b"] (v/sequence-view "ab")))
  (is (= ["x" "y"] (v/sequence-view (json/parse "{\"x\":1,\"y\":2}"))))
  (is (= ["a" "😀"] (v/sequence-view "a😀")))
  (is (= :type (err/error-kind (try (v/sequence-view 5) (catch Exception e e))))))

(deftest code-point-string-order
  (is (neg? (v/compare-strings "ab" "abc")))
  (is (pos? (v/compare-strings "😀" "￿")))
  (is (zero? (v/compare-strings "x" "x"))))

(deftest from-clj-conversion
  (let [d (v/from-clj {:a 1 "b" [1.5 nil] :c {:d true}})]
    (is (= "{'a': 1, 'b': [1.5, None], 'c': {'d': True}}" (v/to-str d)))))
