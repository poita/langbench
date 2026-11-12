(ns spreadsheet.cli-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [spreadsheet.cli :as cli]))

(defn- run-text [text]
  (let [out (atom [])]
    (cli/run (cli/split-lines text) #(swap! out conj %))
    @out))

(deftest split-lines-test
  (is (= ["a" "b"] (cli/split-lines "a\nb\n")))
  (is (= ["a" "b"] (cli/split-lines "a\nb")))
  (is (= [] (cli/split-lines "")))
  (is (= ["a\r"] (cli/split-lines "a\r\n"))))

(deftest example-1-test
  (is (= ["42" "#CYCLE!" "#CYCLE!" "37" "A1 5" "A2 32" "A3 37"]
         (run-text "set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A1\nget A3\nset A1 5\nget A3\ndump"))))

(deftest example-2-test
  (is (= ["A1 Total" "B1 3" "C1 7.5" "B2 4.5" "C2 Total: 7.5" "B3 x" "C3 big"
          "C4 3.75" "C5 2" "C6 #DIV/0!" "C7 #DIV/0!" "C8 0.3333333333"]
         (run-text (str/join "\n" ["set A1 \"Total\"" "set B1 3" "set B2 4.5" "set B3 \"x\""
                                   "set C1 =SUM(B1:B3)" "set C2 =A1&\": \"&C1"
                                   "set C3 =IF(C1>7, \"big\", \"small\")"
                                   "set C4 =AVG(B1:B3)" "set C5 =COUNT(B1:B3)"
                                   "set C6 =B1/(B2-4.5)" "set C7 =C6+1" "set C8 =1/3" "dump"])))))

(deftest example-3-test
  (is (= ["0" "A1 7" "B1 0" "A2 9" "A3 -10" "A4 -6" "A5 1" "A6 33" "A7 1e+20" "A8 1e-05" "A10 2"]
         (run-text (str/join "\n" ["set A1 =1+2*3" "set A2 =(1+2)*3" "set A3 =-2*3-4" "set A4 =2*-3"
                                   "set A5 =1<2+3" "set A6 =1+2&3" "set A7 =100000000000000000000"
                                   "set A8 =0.00001" "set A9 =1234567.891" "set A10 =2/3*3"
                                   "set B1 =A9" "clear A9" "get B1" "dump"])))))

(deftest edge-cases-test
  (is (= [] (run-text "")))
  (is (= [] (run-text "set A1 1")))
  (is (= [""] (run-text "get A1")))
  (is (= ["a  b"] (run-text "set A1 \"a  b\"\nget A1")))
  (is (= ["A1"] (map str/trimr (run-text "set A1 \"\"\ndump"))))
  (is (= ["x😀"] (run-text "set A1 \"x😀\"\nget A1"))))
