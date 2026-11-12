(ns chip8.input-test
  (:require [chip8.input :as input]
            [clojure.test :refer [deftest is testing]]))

(deftest hex-bytes
  (is (= [0x60 0xff 0x00] (input/parse-hex-bytes "60ff00")))
  (is (thrown? clojure.lang.ExceptionInfo (input/parse-hex-bytes "6"))))

(deftest key-schedule
  (is (= [] (input/parse-key-schedule nil)))
  (is (= [] (input/parse-key-schedule "")))
  (is (= [[9 0x0300] [12 0]] (input/parse-key-schedule "9:0300 12:0000"))))

(deftest whole-input
  (testing "with and without optional third line / trailing newline"
    (is (= {:rom [0x12 0x00] :cycles 5 :keys []}
           (input/parse-input "1200\n5")))
    (is (= {:rom [0x12 0x00] :cycles 5 :keys []}
           (input/parse-input "1200\n5\n")))
    (is (= {:rom [0x12 0x00] :cycles 5 :keys []}
           (input/parse-input "1200\n5\n\n")))
    (is (= {:rom [0x12 0x00] :cycles 4000000000 :keys [[0 1] [3 0xffff]]}
           (input/parse-input "1200\n4000000000\n0:0001 3:ffff\n")))))
