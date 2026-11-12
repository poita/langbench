(ns jsonschema.json-test
  (:require [clojure.test :refer [deftest is testing]]
            [jsonschema.json :as json]
            [jsonschema.value :as value]))

(deftest scalars
  (is (nil? (json/parse "null")))
  (is (true? (json/parse " true ")))
  (is (false? (json/parse "false")))
  (is (= "a\"b\\c/d\b\f\n\r\t" (json/parse "\"a\\\"b\\\\c\\/d\\b\\f\\n\\r\\t\""))))

(deftest unicode-strings
  (testing "\\u escapes, including surrogate pairs"
    (is (= "é" (json/parse "\"\\u00e9\"")))
    (is (= "\uD83D\uDCA9" (json/parse "\"\\ud83d\\udca9\"")))
    (is (= 1 (value/code-point-length (json/parse "\"\\ud83d\\udca9\"")))))
  (testing "raw astral characters"
    (is (= 1 (value/code-point-length (json/parse "\"💩\""))))
    (is (= 2 (value/code-point-length (json/parse "\"e\u0301\""))))))

(deftest numbers-are-exact
  (is (value/json-equal? (json/parse "1") (json/parse "1.0")))
  (is (value/json-equal? (json/parse "100") (json/parse "1e2")))
  (is (value/json-equal? (json/parse "-0") (json/parse "0.00")))
  (is (not (value/json-equal? (json/parse "1.0000000000000001") (json/parse "1"))))
  (is (instance? java.math.BigDecimal (json/parse "12345678901234567890123456789")))
  (is (= (java.math.BigDecimal. "1E+400") (json/parse "1e400")))
  (is (pos? (value/compare-numbers (json/parse "1e309") (json/parse "1e308")))))

(deftest containers
  (is (= [] (json/parse "[]")))
  (is (= {} (json/parse "{ }")))
  (is (= {"a" [nil true] "b" {"c" "d"}}
         (json/parse "{\"a\": [null, true], \"b\": {\"c\": \"d\"}}")))
  (is (vector? (json/parse "[1,2]"))))

(deftest malformed-input
  (doseq [bad ["" "[" "[1,]" "{\"a\"}" "{\"a\":1,}" "01" "1." ".5" "-" "1e" "\"abc"
               "\"\\x\"" "\"\\u12\"" "tru" "[1] 2" "'a'" "\"a\nb\""]]
    (is (thrown? clojure.lang.ExceptionInfo (json/parse bad)) (pr-str bad))))

(deftest deep-nesting
  (let [n 2000]
    (is (= n (count (take-while vector?
                                (iterate first
                                         (json/parse (str (apply str (repeat n "["))
                                                          (apply str (repeat n "]"))))))) ))))
