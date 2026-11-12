(ns rrule.cli-test
  (:require [clojure.test :refer [deftest is]]
            [rrule.cli :as cli])
  (:import (java.io BufferedReader BufferedWriter StringReader StringWriter)))

(defn- run-cli [input]
  (let [w (StringWriter.)]
    (with-open [out (BufferedWriter. w)]
      (cli/run (BufferedReader. (StringReader. input)) out))
    (str w)))

(deftest one-output-line-per-input-line
  (is (= "20240101T000000 20240102T000000\n\n"
         (run-cli (str "20240101T000000 FREQ=DAILY;COUNT=2 10\n"
                       "20240101T000000 FREQ=DAILY;UNTIL=20230101T000000 10\n")))))

(deftest missing-final-newline
  (is (= "20240101T000000\n" (run-cli "20240101T000000 FREQ=DAILY 1"))))
