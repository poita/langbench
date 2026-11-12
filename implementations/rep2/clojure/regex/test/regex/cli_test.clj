(ns regex.cli-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [regex.cli :as cli])
  (:import (java.io ByteArrayInputStream ByteArrayOutputStream)))

(defn- run-cli [^String input]
  (let [out (ByteArrayOutputStream.)]
    (cli/run (ByteArrayInputStream. (.getBytes input "ISO-8859-1")) out)
    (.toString out "ISO-8859-1")))

(deftest worked-example-1
  (is (= (str "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n")
         (run-cli (str "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n")))))

(deftest worked-example-2
  (is (= "match 0 2|1,2|0,1\nmatch 0 2|1,2|1,2\nmatch 1 6\nno\n"
         (run-cli "2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n"))))

(deftest worked-example-3
  (is (= (str "match 0 3|2,2\nno\nno\n"
              "match 0 2|0,1\nmatch 0 1|-\n"
              "match 1 2|-|-|-\nmatch 1 3|-|1,2|2,3\nmatch 0 1|-|-|0,1\n")
         (run-cli (str "3\n(a*)*b\n2\naab\nccc\nx$|^(y)?z\n3\nxz\nyz\nzzz\n"
                       "(a){0}b|(c)?(d)\n3\nxb\nxcd\nd\n")))))

(deftest positional-format-edge-cases
  ;; empty pattern, zero subjects, subjects that look like integers or are blank,
  ;; patterns with leading/trailing spaces
  (is (= "" (run-cli "1\na\n0\n")))
  (is (= "match 0 0\nmatch 0 0\n" (run-cli "1\n\n2\n\n  \n")))
  (is (= "match 1 2\nmatch 2 5\nno\n" (run-cli "2\n \n1\nx y\n 1 \n2\n a 1 b\n1\n")))
  (is (= "match 0 1\nmatch 1 2\nno\n" (run-cli "2\n3\n1\n3\n3\n2\n 3\nx\n"))))

(deftest many-groups
  (let [pat (apply str (repeat 50 "(a)"))
        subj (apply str (repeat 50 "a"))
        expected (str "match 0 50" (apply str (for [i (range 50)] (str "|" i "," (inc i)))) "\n")]
    (is (= expected (run-cli (str "1\n" pat "\n1\n" subj "\n"))))))

(deftest long-lines
  (let [s (apply str (repeat 10000 "a"))]
    (is (= "match 0 10000\n" (run-cli (str "1\na*\n1\n" s "\n"))))))
