(ns toml.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [toml.core :as toml]
            [toml.error :as error])
  (:import (java.time LocalDate LocalDateTime LocalTime OffsetDateTime)))

(def doc "title = \"TOML\"
[owner]
dob = 1979-05-27T07:32:00-08:00
[database]
ports = [ 8000, 8001 ]
temp = 1.5
[[products]]
name = \"Hammer\"
[[products]]
name = \"Nail\"
")

(deftest parse-string-types
  (let [m (toml/parse-string doc)]
    (is (= "TOML" (get m "title")))
    (is (= (OffsetDateTime/parse "1979-05-27T07:32:00-08:00") (get-in m ["owner" "dob"])))
    (is (= [8000 8001] (get-in m ["database" "ports"])))
    (is (= 1.5 (get-in m ["database" "temp"])))
    (is (= ["Hammer" "Nail"] (map #(get % "name") (get m "products")))))
  (let [m (toml/parse-string "a = 1979-05-27\nb = 07:32:00.123456789123\nc = 1979-05-27 07:32:00\nd = nan\ne = -inf")]
    (is (= (LocalDate/of 1979 5 27) (get m "a")))
    (is (= (LocalTime/of 7 32 0 123456789) (get m "b")))
    (is (= (LocalDateTime/of 1979 5 27 7 32 0) (get m "c")))
    (is (Double/isNaN (get m "d")))
    (is (= Double/NEGATIVE_INFINITY (get m "e")))))

(deftest key-fn
  (is (= {:a {:b 1}} (toml/parse-string "[a]\nb = 1" {:key-fn keyword}))))

(deftest parse-bytes-validates-utf8
  (is (= {"a" "é"} (toml/parse-bytes (.getBytes "a = \"é\"" "UTF-8"))))
  (doseq [bad [[0x61 0x20 0x3d 0x20 0x22 0xff 0x22]          ; stray byte
               [0x23 0xc0 0xaf]                               ; overlong
               [0x23 0xed 0xa0 0x80]                          ; encoded surrogate
               [0x23 0xe2 0x82]]]                             ; truncated
    (is (thrown? clojure.lang.ExceptionInfo
                 (toml/parse-bytes (byte-array (map unchecked-byte bad)))))))

(deftest errors
  (let [e (try (toml/parse-string "a = 1\na = 2") (catch Exception e e))]
    (is (error/parse-error? e))
    (is (= 2 (:line (ex-data e))))))

(deftest generate
  (is (= "ports = [80, 443]\ntitle = \"Example\"\n"
         (toml/generate-string {:title "Example" :ports [80 443]})))
  (is (= "d = 1979-05-27\nt = 07:32:00.5\n"
         (toml/generate-string {"d" (LocalDate/of 1979 5 27) "t" (LocalTime/of 7 32 0 500000000)})))
  (is (= "x = 2.5000000000000000e+00\n" (toml/generate-string {"x" 2.5})))
  (is (= "dt = 1979-05-27T07:32:00-08:00\n"
         (toml/generate-string {"dt" (OffsetDateTime/parse "1979-05-27T07:32:00-08:00")})))
  (is (thrown? Exception (toml/generate-string {"a" nil})))
  (is (thrown? Exception (toml/generate-string [1 2]))))

(deftest round-trip
  (let [m (toml/parse-string doc)]
    (is (= m (toml/parse-string (toml/generate-string m))))))
