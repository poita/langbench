(ns ordered-map.commands-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [ordered-map.commands :as commands]))

(defn- run [& lines]
  (commands/run-input (str (count lines) "\n" (str/join "\n" lines))))

(deftest example-1
  (is (= "0\nempty\nok\nupdated\nFIVE\nok\nok\n2\n9\n2 5 9\nok\nempty\n"
         (run "size" "min" "insert 5 five" "insert 5 FIVE" "get 5"
              "insert 2 two" "insert 9 nine" "min" "max" "range 2 9"
              "delete 5" "range 3 8"))))

(deftest example-3-extremes
  (is (= (str "ok\nok\nok\nmissing\nmissing\n-9223372036854775808\n"
              "9223372036854775807\n"
              "-9223372036854775808 0 9223372036854775807\nok\n")
         (run "insert -9223372036854775808 lo"
              "insert 9223372036854775807 hi"
              "insert 0 zero"
              "succ 9223372036854775807"
              "pred -9223372036854775808"
              "floor -9223372036854775807"
              "ceil 1"
              "range -9223372036854775808 9223372036854775807"
              "delete 0"))))

(deftest values-are-opaque
  (is (= "ok\nmissing\nmissing\nok\n\"'`\\<>|{}#\nempty\n"
         (run "insert 1 missing" "delete 2" "get 3"
              "insert 4 \"'`\\<>|{}#" "get 4" "range 5 1")
         ) "value `missing` has no special meaning")
  (is (= "ok\nmissing\n" (run "insert 1 empty" "get 2"))))

(deftest empty-inputs
  (is (= "" (commands/run-input "0\n")))
  (is (= "" (commands/run-input "0")))
  (is (= "0\n" (commands/run-input "1\nsize"))))

(deftest rank-select-on-empty
  (is (= "0\nmissing\nempty\n" (run "rank 5" "select 0" "range 1 2"))))
