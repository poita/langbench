(ns diff.main-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [diff.main :as main]))

(defn- lines->input [& ls] (str (str/join "\n" ls) "\n"))

(deftest patch-example
  (is (= (lines->input "6" "a" "B" "c" "c2" "e" "f")
         (main/run (lines->input "patch" "5" "a" "b" "c" "d" "e"
                                 "8" " a" "-b" "+B" " c" "+c2" "-d" " e" "+f")))))

(deftest diff-empty
  (is (= "0\n" (main/run (lines->input "diff" "0" "0")))))

(deftest diff-identical
  (is (= (lines->input "2" " x" " y")
         (main/run (lines->input "diff" "2" "x" "y" "2" "x" "y")))))

(deftest count-like-and-tag-like-content
  ;; content lines that look like counts or tags are read by declared count
  (is (= (lines->input "3" " 5" "+-" "+ ")
         (main/run (lines->input "diff" "1" "5" "3" "5" "-" " ")))))

(deftest whitespace-significant
  (is (= (lines->input "2" "-a " "+a")
         (main/run (lines->input "diff" "1" "a " "1" "a")))))

(deftest patch-empty-result
  (is (= "0\n" (main/run (lines->input "patch" "1" "x" "1" "-x")))))

(deftest non-ascii
  (is (= (lines->input "2" "-é" "+e")
         (main/run (lines->input "diff" "1" "é" "1" "e")))))

(deftest missing-final-newline
  (is (= (lines->input "1" " a")
         (main/run "diff\n1\na\n1\na"))))
