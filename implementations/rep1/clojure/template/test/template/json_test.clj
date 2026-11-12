(ns template.json-test
  (:require [clojure.test :refer [deftest is]]
            [template.json :as json]
            [template.values :as v]))

(deftest scalars
  (is (= 12 (json/parse "12")))
  (is (instance? Long (json/parse "-7")))
  (is (instance? Double (json/parse "1.0")))
  (is (instance? Double (json/parse "1e2")))
  (is (= 100.0 (json/parse "1E2")))
  (is (= true (json/parse " true ")))
  (is (nil? (json/parse "null"))))

(deftest strings
  (is (= "a\"b\\c/d\n\t" (json/parse "\"a\\\"b\\\\c\\/d\\n\\t\"")))
  (is (= "é€😀" (json/parse "\"\\u00e9\\u20ac\\ud83d\\ude00\""))))

(deftest containers-keep-order
  (let [d (json/parse "{\"z\": 1, \"a\": [1, 2, {\"k\": null}], \"m\": {}}")]
    (is (= ["z" "a" "m"] (v/sequence-view d)))
    (is (= [1 2] (subvec (.get d "a") 0 2)))))

(deftest errors
  (doseq [bad ["" "{" "[1,]" "{\"a\" 1}" "tru" "\"abc" "1 2" "{\"a\":}"]]
    (is (thrown? clojure.lang.ExceptionInfo (json/parse bad)) bad)))
