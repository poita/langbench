(ns qrcode.cli-test
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [qrcode.cli :as cli])
  (:import (java.io ByteArrayInputStream ByteArrayOutputStream)
           (java.nio.charset StandardCharsets)))

(defn- run [^String input]
  (let [out (ByteArrayOutputStream.)]
    (cli/process (ByteArrayInputStream. (.getBytes input StandardCharsets/UTF_8)) out)
    (.toString out "UTF-8")))

(defn- fixture [n] (slurp (io/resource n)))

(deftest split-lines-handles-optional-final-newline
  (is (= ["a" "b"] (map #(String. ^bytes %) (cli/split-lines (.getBytes "a\nb")))))
  (is (= ["a" "b"] (map #(String. ^bytes %) (cli/split-lines (.getBytes "a\nb\n")))))
  (is (= [] (cli/split-lines (.getBytes "")))))

(deftest parse-query-keeps-interior-spaces
  (let [[ecl mask text] (cli/parse-query (.getBytes "Q auto hello  big world" StandardCharsets/UTF_8))]
    (is (= :q ecl))
    (is (= :auto mask))
    (is (= "hello  big world" (String. ^bytes text StandardCharsets/UTF_8)))))

(deftest parse-query-rejects-malformed-lines
  (doseq [bad ["" "L" "L 0" "L 0 " "X 0 abc" "L 9 abc" "L x abc"]]
    (is (thrown? clojure.lang.ExceptionInfo (cli/parse-query (.getBytes ^String bad))) bad)))

(deftest queries-are-answered-in-order
  (let [expected (str (fixture "example1.out") (fixture "example2.out") (fixture "example3.out"))
        input (str/join "\n" (map #(str/trim (fixture (str "example" % ".in"))) [1 2 3]))]
    (is (= expected (run input)))
    (is (= expected (run (str input "\n"))))))
