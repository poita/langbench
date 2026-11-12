(ns json.parse-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [json.parse :as parse]
            [json.tree :as tree])
  (:import (java.nio.charset StandardCharsets)))

(defn- utf8 ^bytes [^String s] (.getBytes s StandardCharsets/UTF_8))

(defn- parse-str [s] (parse/parse-bytes (utf8 s)))

(defn- invalid-str? [s]
  (try (parse-str s) false
       (catch clojure.lang.ExceptionInfo e (parse/invalid? e))))

(deftest scalars
  (is (nil? (parse-str "null")))
  (is (true? (parse-str " true ")))
  (is (false? (parse-str "\t\r\nfalse\n")))
  (is (= "a\"b\\c/\b\f\n\r\t" (parse-str "\"a\\\"b\\\\c\\/\\b\\f\\n\\r\\t\"")))
  (is (= "é😀" (parse-str "\"\\u00e9\\uD83D\\uDE00\"")))
  (is (= "😀" (parse-str "\"😀\""))))

(deftest numbers-keep-canonical-text
  (doseq [[in out] {"0" "0", "-0" "-0", "10" "10", "1.0" "1.0", "1.50" "1.50"
                    "1E5" "1e5", "1e+05" "1e5", "1e-007" "1e-7", "1e-0" "1e0"
                    "1E+00" "1e0", "-0.0" "-0.0", "0e0" "0e0"
                    "2.5E-000789" "2.5e-789"
                    "123456789012345678901234567890" "123456789012345678901234567890"}]
    (is (= out (tree/number-text (parse-str in))) in)))

(deftest containers
  (is (= [] (parse-str "[ ]")))
  (is (= [nil true] (parse-str "[null,true]")))
  (is (= [] (tree/members (parse-str "{ }"))))
  (testing "objects keep every member in order, duplicates included"
    (is (= [["b" true] ["a" false] ["b" nil]]
           (map vec (tree/members (parse-str "{\"b\":true,\"a\":false,\"b\":null}")))))))

(deftest invalid-documents
  (doseq [s ["" "   " "\f1" "1\u000B" "\u00A01" "\u20281" "1\u0000"
             "tru" "True" "NaN" "Infinity" "-Infinity" "nul" "nullx"
             "01" "+1" "-" "1." ".5" "1e" "1e+" "1E+-5" "1e5e5" "0x1" "- 1" "1 .5"
             "\u0662" "\u00B2" "\uFF11"
             "[1,]" "[,1]" "[1 2]" "{\"a\":1,}" "{\"a\" 1}" "{a:1}" "{1:1}" "{'a':1}"
             "[1] 2" "1 2" "// c\n1" "/* c */ 1" "[" "{" "[1" "{\"a\"" "{\"a\":" "]" "}"
             "\"abc" "\"\\" "[\"\\" "\"\t\"" "\"\n\"" "\"\u0000\""
             "\"\\x\"" "\"\\U0041\"" "\"\\'\"" "\"\\0\"" "\"\\u12\"" "\"\\u12G4\""
             "\"\\u\uFF11\uFF11\uFF11\uFF11\""
             "\"\\uD800\"" "\"\\uD800\\u0041\"" "\"\\uD800\\uE000\"" "\"\\uD800\\uDBFF\""
             "\"\\uD800x\"" "\"\\uDC00\"" "{\"\\uD800\":1}"
             "{\"a\":\"\\uD800\",\"a\":1}" "{\"a\":[1,],\"a\":1}"
             "\uFEFF1"]]
    (is (invalid-str? s) (pr-str s))))

(deftest invalid-utf8
  (doseq [bs [[0x22 0xC0 0xAF 0x22] [0x22 0xED 0xA0 0x80 0x22] [0x22 0xF4 0x90 0x80 0x80 0x22]
              [0x22 0xE2 0x82 0x22] [0xEF 0xBB 0xBF 0x31] [0x31 0x20 0xFF]]]
    (is (try (parse/parse-bytes (byte-array (map unchecked-byte bs))) false
             (catch clojure.lang.ExceptionInfo e (parse/invalid? e)))
        (pr-str bs))))

(deftest nesting-depth
  (letfn [(nest [n inner] (str (str/join (repeat n "[")) inner (str/join (repeat n "]"))))]
    (is (vector? (parse-str (nest 512 ""))))
    (is (invalid-str? (nest 513 "")))
    (is (invalid-str? (nest 512 "{}")))
    (is (vector? (parse-str (nest 511 "{}"))))
    (is (invalid-str? (str/join (repeat 100000 "["))))
    (is (invalid-str? (str (str/join (repeat 2000 "{\"a\":")) "1")))))

(deftest error-data
  (let [e (try (parse-str "[1,]") (catch clojure.lang.ExceptionInfo e e))]
    (is (parse/invalid? e))
    (is (= 3 (:pos (ex-data e))))
    (is (not (parse/invalid? (ex-info "other" {}))))
    (is (not (parse/invalid? (RuntimeException.))))))
