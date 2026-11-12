(ns json.cli-test
  (:require [clojure.test :refer [deftest is]]
            [json.cli :as cli])
  (:import (java.io ByteArrayInputStream ByteArrayOutputStream)
           (java.nio.charset StandardCharsets)))

(defn- run-bytes ^String [^bytes in]
  (let [out (ByteArrayOutputStream.)]
    (cli/run (ByteArrayInputStream. in) out)
    (String. (.toByteArray out) StandardCharsets/UTF_8)))

(defn- run-str [^String s]
  (run-bytes (.getBytes s StandardCharsets/UTF_8)))

(deftest valid-input-prints-canonical-line
  (is (= "{\"a\":1,\"b\":[]}\n" (run-str " {\"b\": [ ], \"a\": 1}\n")))
  (is (= "1e5\n" (run-str "1E+05"))))

(deftest invalid-input-prints-invalid
  (is (= "invalid\n" (run-str "")))
  (is (= "invalid\n" (run-str "  \n")))
  (is (= "invalid\n" (run-str "[1,]")))
  (is (= "invalid\n" (run-bytes (byte-array [0xEF 0xBB 0xBF 0x31]))))
  (is (= "invalid\n" (run-bytes (byte-array [0x22 (unchecked-byte 0xFF) 0x22])))))

(deftest large-input
  (let [n    100000
        doc  (str "[" (apply str (interpose "," (range n))) "]")
        out  (run-str doc)]
    (is (= (str doc "\n") out))))
