(ns jq.json-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [jq.json :as json]
            [jq.value :as v]))

(deftest parse-scalars
  (is (nil? (json/parse "null")))
  (is (true? (json/parse " true ")))
  (is (false? (json/parse "false")))
  (is (= 12.0 (json/parse "12")))
  (is (= -2.5 (json/parse "-2.5")))
  (is (= 100.0 (json/parse "1e2")))
  (is (= "a\"b\\c/\b\f\n\r\t" (json/parse "\"a\\\"b\\\\c\\/\\b\\f\\n\\r\\t\""))))

(deftest parse-unicode
  (is (= "é" (json/parse "\"\\u00e9\"")))
  (is (= "é" (json/parse "\"\\u00E9\"")))
  (is (= "😀" (json/parse "\"\\ud83d\\ude00\"")))
  (is (= "😀é" (json/parse "\"😀é\""))))

(deftest parse-containers
  (is (= [] (json/parse "[]")))
  (is (= [1.0 [2.0] nil] (json/parse "[1, [2],\n null]")))
  (is (= ["b" "a"] (v/obj-keys (json/parse "{\"b\":1,\"a\":2}"))))
  (is (= v/empty-obj (json/parse " { } "))))

(deftest parse-errors
  (doseq [bad ["" "[1,]" "{\"a\"}" "[1 2]" "\"abc" "tru" "1 2" "{\"a\":1" "-"]]
    (testing bad
      (is (thrown? clojure.lang.ExceptionInfo (json/parse bad))))))

(deftest stringify-numbers
  (is (= "3" (json/stringify 3.0)))
  (is (= "-12" (json/stringify -12.0)))
  (is (= "1000000000000" (json/stringify 1e12)))
  (is (= "1.5" (json/stringify 1.5)))
  (is (= "0.125" (json/stringify 0.125)))
  (is (= "3086419725308.5" (json/stringify 3086419725308.5)))
  (is (= "0.001" (json/stringify 0.001))))

(deftest stringify-strings
  (is (= "\"a\\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u007f/<>&é😀\""
         (json/stringify "a\"\\\b\f\n\r\t\u0001\u007f/<>&é😀"))))

(deftest stringify-containers-keep-order
  (is (= "{\"z\":1,\"a\":[true,null,\"x\"]}"
         (json/stringify (v/object "z" 1.0 "a" [true nil "x"]))))
  (is (= "{}" (json/stringify v/empty-obj)))
  (is (= "[]" (json/stringify []))))

(def gen-json
  (gen/recursive-gen
   (fn [inner]
     (gen/one-of [(gen/vector inner 0 4)
                  (gen/fmap #(apply v/object (mapcat identity %))
                            (gen/vector (gen/tuple gen/string-alphanumeric inner) 0 4))]))
   (gen/one-of [(gen/return nil) gen/boolean
                (gen/fmap double gen/small-integer)
                (gen/fmap #(/ (double %) 8) gen/small-integer)
                gen/string])))

(defspec roundtrip-text 200
  (prop/for-all [x gen-json]
    (let [text (json/stringify x)]
      (= text (json/stringify (json/parse text))))))

(defspec roundtrip-value 200
  (prop/for-all [x gen-json]
    (v/equal? x (json/parse (json/stringify x)))))
