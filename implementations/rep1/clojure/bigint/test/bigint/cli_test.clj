(ns bigint.cli-test
  (:require [bigint.cli :as cli]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]])
  (:import (java.io StringReader StringWriter)))

(defn- run-str [input]
  (let [w (StringWriter.)]
    (cli/run (StringReader. input) w)
    (str w)))

(deftest spec-examples
  (testing "example 1"
    (is (= "42\n-2\n-3\n-1\n"
           (run-str "12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n"))))
  (testing "example 2, no trailing newline on input"
    (is (= "0\n0\n0\n100000000000000000000\n1024\n1\n"
           (run-str "-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0"))))
  (testing "example 3"
    (is (= (str "error\nerror\nerror\n"
                "-121932631137021795226185032733622923332237463801111263526900\n"
                "999999999999999999999999999999\n-1\n")
           (run-str (str "1 / 0\n0 % 0\n2 ^ -1\n"
                         "-123456789012345678901234567890 * 987654321098765432109876543210\n"
                         "1000000000000000000000000000000 - 1\n-3 cmp -2\n"))))))

(deftest empty-input
  (is (= "" (run-str ""))))

(deftest error-cases
  (is (= "error" (cli/evaluate "5 / -0")))
  (is (= "error" (cli/evaluate "5 % 0")))
  (is (= "error" (cli/evaluate "2 ^ -3")))
  (is (= "1" (cli/evaluate "5 ^ -0")))
  (is (= "1" (cli/evaluate "-0 ^ -00"))))

(deftest negative-zero-never-printed
  (doseq [q ["-5 * 0" "-7 % 7" "-1 / 2" "-0 + 0" "0 - 0" "-0 ^ 3"]]
    (is (= "0" (cli/evaluate q)) q)))

(deftest cmp-results
  (is (= "0" (cli/evaluate "-0 cmp 0")))
  (is (= "-1" (cli/evaluate "-3 cmp -2")))
  (is (= "1" (cli/evaluate "10 cmp 9"))))

(deftest large-operands
  (let [n (apply str (repeat 5000 "9"))
        one-followed (str "1" (apply str (repeat 5000 "0")))]
    (is (= one-followed (cli/evaluate (str n " + 1"))))
    (is (= (str (apply str (repeat 4999 "9")) "8" (apply str (repeat 4999 "0")) "1")
           (cli/evaluate (str n " * " n))))
    (is (= (str n "\n") (str (cli/evaluate (str one-followed " - 1")) "\n")))
    (is (= "0" (cli/evaluate (str one-followed " % " one-followed))))
    (is (= n (cli/evaluate (str (str/join [n "0"]) " / 10"))))))
