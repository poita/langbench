(ns spreadsheet.core-test
  (:require [clojure.test :refer [deftest is testing are]]
            [spreadsheet.core :as ss]))

(defn- sheet [& cmds]
  (reduce (fn [s [n c]] (if c (ss/set-cell s n c) (ss/clear-cell s n)))
          (ss/empty-sheet) (partition 2 2 [nil] cmds)))

(defn- shows
  "Builds a sheet from `cmds` and returns the displayed value of A9."
  [formula & more]
  (ss/display (apply sheet "A9" formula more) "A9"))

(deftest literals-test
  (let [s (sheet "A1" "5" "A2" "\"hi\"" "A3" "-0" "A4" "\"\"")]
    (is (= 5.0 (ss/value s "A1")))
    (is (= "hi" (ss/value s "A2")))
    (is (= "0" (ss/display s "A3")))
    (is (= "" (ss/value s "A4")))
    (is (nil? (ss/value s "B1")))
    (is (= "" (ss/display s "B1")))))

(deftest arithmetic-test
  (are [f r] (= r (shows f))
    "=1+2*3" "7"
    "=(1+2)*3" "9"
    "=-2*3-4" "-10"
    "=2*-3" "-6"
    "=--5" "5"
    "=1/3" "0.3333333333"
    "=2/3*3" "2"
    "=1/0" "#DIV/0!"
    "=1/-0" "#DIV/0!"
    "=\"5\"+1" "#VALUE!"
    "=-\"a\"" "#VALUE!"
    "=1/0.0000001*0.0000001" "1"))

(deftest overflow-test
  (let [big (str "1" (apply str (repeat 300 "0")))
        tiny (str "0." (apply str (repeat 299 "0")) "1")]
    (is (= "#VALUE!" (shows (str "=" big "*" big))))
    (is (= "#VALUE!" (shows (str "=SUM(" (clojure.string/join "," (repeat 20 (str big "*10000000"))) ")"))))
    (is (= "#VALUE!" (shows (str "=AVG(" (clojure.string/join "," (repeat 20 (str big "*10000000"))) ")"))))
    (is (= "1e-300" (shows (str "=" tiny))))
    (is (= "0" (shows (str "=" tiny "*" tiny))))))

(deftest strings-and-comparisons-test
  (are [f r] (= r (shows f))
    "=1+2&3" "33"
    "=\"a\"&\"b\"" "ab"
    "=1/4&\"x\"" "0.25x"
    "=1<2" "1"
    "=2<=1" "0"
    "=1=1" "1"
    "=1<>1" "0"
    "=\"a\"<\"b\"" "1"
    "=\"a\"<\"B\"" "0"
    "=\"ab\">\"a\"" "1"
    "=\"1\"=1" "0"
    "=\"1\"<>1" "1"
    "=\"1\"<1" "#VALUE!"
    "=\"😀\">\"ｚ\"" "1"
    "=\"😀\"<\"ｚ\"" "0"))

(deftest empty-cells-test
  (are [f r] (= r (shows f))
    "=Z1" "0"
    "=Z1+1" "1"
    "=(Z1)&\"x\"" "x"
    "=IF(1,Z1,7)&\"x\"" "x"
    "=(Z1)=\"\"" "1"
    "=Z1=0" "1"
    "=Z1=Y1" "1"
    "=Z1<1" "1"
    "=COUNT((Z1))" "0"
    "=-Z1&\"x\"" "0x"
    "=SUM(Z1:Z3)" "0"
    "=AVG(Z1:Z3)" "#DIV/0!"
    "=MIN(Z1:Z3)" "0"))

(deftest if-test
  (are [f r] (= r (shows f))
    "=IF(1,\"a\",1/0)" "a"
    "=IF(0,1/0,\"b\")" "b"
    "=IF(\"x\",1,2)" "#VALUE!"
    "=IF(Z1,1,2)" "2"
    "=IF(1/0,1,2)" "#DIV/0!"
    "=IF(-0.5,1,2)" "1"))

(deftest aggregates-test
  (let [s (sheet "A1" "1" "A2" "2" "A3" "3" "A4" "\"text\"" "B1" "4")
        at (fn [f] (-> s (ss/set-cell "C1" f) (ss/display "C1")))]
    (are [f r] (= r (at f))
      "=SUM(A1:A3)" "6"
      "=SUM(A3:A1)" "6"
      "=SUM(A1:B1)" "5"
      "=SUM(A1:A4)" "6"
      "=COUNT(A1:A4)" "3"
      "=AVG(A1:A4)" "2"
      "=MIN(A1:B1,0.5)" "0.5"
      "=MAX(A1:B1,100)" "100"
      "=SUM(1,2,A1:A2)" "6"
      "=SUM(\"a\")" "#VALUE!"
      "=SUM(A4)" "#VALUE!"
      "=SUM(A1:A3,1/0)" "#DIV/0!"
      "=SUM(1/0,\"a\")" "#DIV/0!"
      "=SUM(\"a\",1/0)" "#VALUE!"
      "=COUNT(B1,Z1,5)" "2"
      "=SUM(A1:A3)*2" "12")))

(deftest invalid-refs-test
  (are [f] (= "#REF!" (shows f))
    "=AAA1" "=A0" "=A10000" "=A01" "=1+ZZZ5" "=IF(1,2,AAA1)" "=SUM(A1:A0)"))

(deftest recalculation-test
  (let [s (sheet "A1" "10" "A2" "32" "A3" "=A1+A2")]
    (is (= "42" (ss/display s "A3")))
    (testing "changes propagate"
      (is (= "37" (-> s (ss/set-cell "A1" "5") (ss/display "A3")))))
    (testing "clearing a cell"
      (is (= "32" (-> s (ss/clear-cell "A1") (ss/display "A3"))))
      (is (= "" (-> s (ss/clear-cell "A3") (ss/display "A3")))))
    (testing "replacing a formula changes its dependencies"
      (let [s (-> s (ss/set-cell "A3" "=A2") (ss/set-cell "A1" "100"))]
        (is (= "32" (ss/display s "A3")))))
    (testing "chains"
      (let [s (reduce (fn [s i] (ss/set-cell s (str "A" (inc i)) (str "=A" i "+1")))
                      (ss/set-cell (ss/empty-sheet) "A1" "1") (range 1 3000))]
        (is (= "3000" (ss/display s "A3000")))
        (is (= "6000" (ss/display (ss/set-cell s "A1" "3001") "A3000")))))))

(deftest cycles-test
  (testing "self reference and range containing self"
    (is (= "#CYCLE!" (shows "=A9+1")))
    (is (= "#CYCLE!" (shows "=SUM(A1:A9)"))))
  (let [s (sheet "A1" "10" "A2" "32" "A3" "=A1+A2")
        c (ss/set-cell s "A1" "=A3")]
    (testing "cyclic cells and their readers"
      (is (= "#CYCLE!" (ss/display c "A1")))
      (is (= "#CYCLE!" (ss/display c "A3")))
      (is (= "32" (ss/display c "A2")))
      (is (= "#CYCLE!" (-> c (ss/set-cell "B1" "=A1+1") (ss/display "B1")))))
    (testing "breaking the cycle"
      (is (= "37" (-> c (ss/set-cell "A1" "5") (ss/display "A3"))))
      (is (= "32" (-> c (ss/clear-cell "A1") (ss/display "A3")))))
    (testing "IF can mask a cyclic read, but dependencies stay static"
      (is (= "7" (-> c (ss/set-cell "B1" "=IF(1,7,A1)") (ss/display "B1"))))
      (is (= "#CYCLE!" (-> (sheet "A1" "=IF(1,5,A1)") (ss/display "A1"))))
      (is (= "7" (-> c (ss/set-cell "B1" "=IF(0,A1,7)") (ss/display "B1")))))
    (testing "a cycle through a cell edited later"
      (let [s (sheet "A1" "=B1" "B1" "=C1" "C1" "1")]
        (is (= "1" (ss/display s "A1")))
        (let [s (ss/set-cell s "C1" "=A1")]
          (is (= ["#CYCLE!" "#CYCLE!" "#CYCLE!"] (map #(ss/display s %) ["A1" "B1" "C1"])))
          (is (= "2" (-> s (ss/set-cell "C1" "2") (ss/display "A1")))))))))

(deftest dump-test
  (is (= [] (ss/dump (ss/empty-sheet))))
  (is (= [["A1" "1"] ["B1" "x"] ["A2" ""] ["C2" "3"] ["A10" "0"]]
         (ss/dump (sheet "A10" "=Q1" "C2" "3" "A2" "\"\"" "B1" "\"x\"" "A1" "1")))))

(deftest invalid-name-test
  (is (thrown? clojure.lang.ExceptionInfo (ss/value (ss/empty-sheet) "A0"))))

(deftest source-test
  (is (= "=A1+1" (ss/source (sheet "A2" "=A1+1") "A2")))
  (is (nil? (ss/source (sheet) "A2"))))
