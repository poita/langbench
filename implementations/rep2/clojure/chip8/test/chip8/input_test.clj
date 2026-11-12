(ns chip8.input-test
  (:require [clojure.test :refer [deftest is]]
            [chip8.input :as input]))

(deftest parse-hex
  (is (= [0x60 0xff 0x00] (input/parse-hex-bytes "60ff00"))))

(deftest parse-schedule
  (is (= [] (input/parse-schedule nil)))
  (is (= [] (input/parse-schedule "")))
  (is (= [[9 0x300] [12 0]] (input/parse-schedule "9:0300 12:0000"))))

(deftest parse-input
  (is (= {:rom [0x12 0x00] :cycles 5 :schedule []}
         (input/parse-input "1200\n5\n")))
  (is (= {:rom [0x12 0x00] :cycles 5 :schedule [[1 0xffff]]}
         (input/parse-input "1200\n5\n1:ffff")))
  (is (= {:rom [0x12 0x00] :cycles 4000000000 :schedule []}
         (input/parse-input "1200\n4000000000"))))
