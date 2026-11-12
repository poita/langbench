(ns orderbook.stream-test
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [orderbook.stream :as stream])
  (:import (java.io BufferedReader StringReader StringWriter)))

(defn- run-text [^String input]
  (let [out (StringWriter.)]
    (stream/process! (BufferedReader. (StringReader. input)) out)
    (str out)))

(defn- resource-text [name] (slurp (io/resource name)))

(deftest worked-examples
  (doseq [n ["example1" "example2" "example3" "no_trailing_newline" "empty"]]
    (testing n
      (is (= (resource-text (str n ".out"))
             (run-text (resource-text (str n ".in"))))))))

(deftest empty-input
  (is (= "" (run-text "0\n")))
  (is (= "" (run-text ""))))

(deftest every-event-line-ends-with-newline
  (is (= "REST a\nCANCEL a 1\n--\n"
         (run-text "3\nLIMIT a BUY 1 1\nCANCEL a\nBOOK"))))

(deftest only-n-commands-are-processed
  (is (= "REST a\n" (run-text "1\nLIMIT a BUY 1 1\nBOOK\n"))))
