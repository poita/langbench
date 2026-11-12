(ns jq.json-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [jq.json :as json]
            [jq.value :as v]))

(deftest parse-scalars
  (is (nil? (json/parse " null ")))
  (is (true? (json/parse "true")))
  (is (= 12.5 (json/parse "12.5")))
  (is (= -3.0 (json/parse "-3")))
  (is (= "a\"b\\c/\b\f\n\r\t" (json/parse "\"a\\\"b\\\\c\\/\\b\\f\\n\\r\\t\"")))
  (is (= "\uD83D\uDE00" (json/parse "\"\\ud83d\\ude00\"")))
  (is (= "é😀" (json/parse "\"é😀\""))))

(deftest parse-containers
  (is (= [1.0 [] "x"] (json/parse "[1, [], \"x\"]")))
  (let [o (json/parse "{\"b\":1,\"a\":{\"z\":null}}")]
    (is (v/obj? o))
    (is (= ["a" "b"] (v/sorted-keys o)))
    (is (= "{\"b\":1,\"a\":{\"z\":null}}" (json/stringify o)))))

(deftest parse-errors
  (doseq [bad ["" "[1,]" "{\"a\"}" "[1" "\"abc" "tru" "1 2" "{\"a\":1,}"]]
    (is (thrown? clojure.lang.ExceptionInfo (json/parse bad)) bad)))

(deftest number-formatting
  (is (= "3" (json/format-number 3.0)))
  (is (= "-12" (json/format-number -12.0)))
  (is (= "1000000000000" (json/format-number 1e12)))
  (is (= "1.5" (json/format-number 1.5)))
  (is (= "0.125" (json/format-number 0.125)))
  (is (= "3086419725308.5" (json/format-number 3086419725308.5)))
  (is (= "0.001" (json/format-number 0.001)))
  (is (= "9007199254740991" (json/format-number 9007199254740991.0))))

(deftest string-escaping
  (is (= "\"\\u0001\\u001f\\u007f\\n\\\"\\\\é/\"" (json/stringify "\u0001\u001f\u007f\n\"\\é/"))))

(deftest parse-number-strict
  (is (= 12.0 (json/parse-number "12")))
  (is (= -2.5 (json/parse-number "-2.5")))
  (doseq [bad ["" " 1" "1 " "abc" "007" "1." ".5" "NaN" "0x10"]]
    (is (nil? (json/parse-number bad)) bad)))

(def gen-json
  (gen/recursive-gen
   (fn [inner]
     (gen/one-of [(gen/vector inner 0 5)
                  (gen/fmap #(v/obj-from-pairs %)
                            (gen/vector (gen/tuple gen/string-alphanumeric inner) 0 5))]))
   (gen/one-of [(gen/return nil) gen/boolean
                (gen/fmap double gen/small-integer)
                (gen/fmap #(/ (double %) 8) gen/small-integer)
                gen/string])))

(defspec roundtrip-through-text 200
  (prop/for-all [x gen-json]
    (v/equal? x (json/parse (json/stringify x)))))

(defspec stringify-is-stable 200
  (prop/for-all [x gen-json]
    (let [s (json/stringify x)] (= s (json/stringify (json/parse s))))))
