(ns bigint.query-test
  (:require [bigint.query :as q]
            [clojure.test :refer [deftest is testing]]))

(deftest spec-examples
  (doseq [[line out] [["12 + 30" "42"]
                      ["5 - 7" "-2"]
                      ["-7 / 2" "-3"]
                      ["-7 % 2" "-1"]
                      ["-0 + 0" "0"]
                      ["007 cmp 7" "0"]
                      ["-5 * 0" "0"]
                      ["99999999999999999999 + 1" "100000000000000000000"]
                      ["2 ^ 10" "1024"]
                      ["0 ^ 0" "1"]
                      ["1 / 0" "error"]
                      ["0 % 0" "error"]
                      ["2 ^ -1" "error"]
                      ["-123456789012345678901234567890 * 987654321098765432109876543210"
                       "-121932631137021795226185032733622923332237463801111263526900"]
                      ["1000000000000000000000000000000 - 1" "999999999999999999999999999999"]
                      ["-3 cmp -2" "-1"]]]
    (is (= out (q/evaluate line)) line)))

(deftest zero-edge-cases
  (is (= "1" (q/evaluate "5 ^ -0")))
  (is (= "1" (q/evaluate "-0 ^ -00")))
  (is (= "error" (q/evaluate "5 / -0")))
  (is (= "0" (q/evaluate "-7 % 7")))
  (is (= "0" (q/evaluate "-1 / 2")))
  (is (= "0" (q/evaluate "-0 cmp 000")))
  (is (= "-1" (q/evaluate "-1 ^ 999"))))

(deftest comparison-results
  (is (= "1" (q/evaluate "10 cmp 9")))
  (is (= "-1" (q/evaluate "-10 cmp 9")))
  (is (= "1" (q/evaluate "-9 cmp -10"))))

(deftest malformed-lines
  (is (thrown? clojure.lang.ExceptionInfo (q/evaluate "1 +")))
  (is (thrown? clojure.lang.ExceptionInfo (q/evaluate "1 + 2 3")))
  (is (thrown? clojure.lang.ExceptionInfo (q/evaluate "1 ? 2"))))
