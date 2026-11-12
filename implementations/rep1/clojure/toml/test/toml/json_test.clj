(ns toml.json-test
  (:require [clojure.test :refer [deftest is]]
            [toml.data :as d]
            [toml.json :as json]))

(deftest writer-sorts-and-escapes
  (is (= "{\"A\":[],\"a\":{\"type\":\"string\",\"value\":\"q\\\"\\\\\\b\\f\\n\\r\\t\\u0001\u007f\u00e9\"},\"\u00e9\":{}}"
         (json/write-tagged {"\u00e9" {} "a" (d/scalar :string "q\"\\\b\f\n\r\t\u0001\u007f\u00e9") "A" []}))))

(deftest sorts-by-code-point
  (is (= "{\"\uff5e\":{},\"\ud83d\ude00\":{}}"
         (json/write-tagged {"\ud83d\ude00" {} "\uff5e" {}}))
      "U+FF5E sorts before U+1F600 although its UTF-16 unit is larger"))

(deftest reader
  (is (= {"a" (d/scalar :integer "1") "t" {"x" []} "l" [(d/scalar :bool "true") {}]}
         (json/read-tagged
          " { \"a\" : {\"value\":\"1\", \"type\":\"integer\"},\n \"t\":{\"x\":[ ]},
              \"l\":[{\"type\":\"bool\",\"value\":\"true\"},{}] } "))))

(deftest reader-escapes
  (is (= "\u00e9\ud83d\ude00\n/" (:value (json/read-tagged "{\"type\":\"string\",\"value\":\"\\u00e9\\ud83d\\ude00\\n\\/\"}")))))

(deftest table-with-type-and-value-keys
  (is (= {"type" {"x" (d/scalar :bool "false")} "value" []}
         (json/read-tagged "{\"type\":{\"x\":{\"type\":\"bool\",\"value\":\"false\"}},\"value\":[]}"))))
