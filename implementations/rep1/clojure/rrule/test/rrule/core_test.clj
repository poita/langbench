(ns rrule.core-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [rrule.core :as rrule]))

(defn- line [s] (rrule/expand-line s))

(deftest spec-worked-examples
  (is (= (str "19970926T090000 19971128T090000 19980130T090000 19980327T090000 19980529T090000 "
              "19980731T090000 19980925T090000 19981127T090000 19990129T090000 19990326T090000")
         (line "19970902T090000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=10 100")))
  (is (= (str "19970902T090000 19970904T090000 19970916T090000 19970918T090000 "
              "19970930T090000 19971002T090000 19971014T090000 19971016T090000")
         (line "19970902T090000 FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH;COUNT=8 100")))
  (is (= "19970902T090000 19970907T090000 19970916T090000 19970921T090000"
         (line "19970902T090000 FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4 4"))))

(deftest spec-defaults-and-month-ends
  (is (= "20240229T120000 20280229T120000 20320229T120000"
         (line "20240229T120000 FREQ=YEARLY;COUNT=3 10")))
  (is (= "20240131T000000 20240229T000000 20240331T000000 20240430T000000"
         (line "20240131T000000 FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240430T000000 10")))
  (is (= "20240329T080000 20240430T080000 20240531T080000"
         (line "20240301T080000 FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3 10")))
  (is (= "" (line "20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5 10"))))

(deftest spec-week-numbers
  (is (= "20201228T000000 20261228T000000 20321227T000000"
         (line "20200101T000000 FREQ=YEARLY;BYWEEKNO=53;BYDAY=MO;COUNT=3 10")))
  (is (= "20110101T000000 20110102T000000 20151228T000000 20151229T000000"
         (line "20110101T000000 FREQ=YEARLY;BYWEEKNO=53;COUNT=4 10"))))

(deftest monthly-bymonthday-31
  (is (= "20240131T000000 20240331T000000 20240531T000000"
         (line "20240131T000000 FREQ=MONTHLY;COUNT=3 10"))))

(deftest bysetpos-only
  (testing "BYSETPOS acts on the defaulted days"
    (is (= "20240115T000000 20240215T000000"
           (line "20240115T000000 FREQ=MONTHLY;BYSETPOS=1;COUNT=2 10")))
    (is (= "" (line "20240115T000000 FREQ=MONTHLY;BYSETPOS=2;COUNT=2 10"))))
  (testing "BYSETPOS is applied before the DTSTART check"
    (is (= "20240401T000000"
           (line "20240320T000000 FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;COUNT=1 10")))))

(deftest ordinal-byday
  (testing "yearly with BYMONTH: per-month ordinals"
    (is (= "20240108T000000 20240708T000000 20250113T000000"
           (line "20240101T000000 FREQ=YEARLY;BYMONTH=1,7;BYDAY=2MO;COUNT=3 10"))))
  (testing "yearly without BYMONTH: whole-year ordinals"
    (is (= "20241227T000000 20251226T000000"
           (line "20240101T000000 FREQ=YEARLY;BYDAY=-1FR;COUNT=2 10"))))
  (testing "nonexistent designated days contribute nothing"
    (is (= "20240129T000000 20240429T000000"
           (line "20240101T000000 FREQ=MONTHLY;BYDAY=5MO;COUNT=2 10")))))

(deftest until-and-limits
  (testing "UNTIL is inclusive and may precede DTSTART"
    (is (= "20240101T000000 20240102T000000"
           (line "20240101T000000 FREQ=DAILY;UNTIL=20240102T000000 10")))
    (is (= "" (line "20240101T000000 FREQ=DAILY;UNTIL=20231231T000000 10"))))
  (testing "N limits the output"
    (is (= "20240101T000000 20240102T000000"
           (line "20240101T000000 FREQ=DAILY;COUNT=5 2"))))
  (testing "occurrences before DTSTART are not counted"
    (is (= "20240110T000000 20240115T000000"
           (line "20240110T000000 FREQ=WEEKLY;BYDAY=MO,WE;WKST=MO;COUNT=2 5")))))

(deftest year-9999-bound
  (is (= "99991230T000000 99991231T000000"
         (line "99991230T000000 FREQ=DAILY 10")))
  (is (= "99991201T000000" (line "99991201T000000 FREQ=MONTHLY 10"))))

(deftest public-api
  (is (= [{:year 2024 :month 2 :day 29 :hour 12 :minute 0 :second 0}
          {:year 2028 :month 2 :day 29 :hour 12 :minute 0 :second 0}]
         (rrule/occurrences "20240229T120000" "FREQ=YEARLY" {:limit 2})))
  (is (= ["19970902T090000" "19970903T090000"]
         (rrule/occurrence-strings {:year 1997 :month 9 :day 2 :hour 9 :minute 0 :second 0}
                                   (rrule/parse-rule "FREQ=DAILY;COUNT=2"))))
  (is (= 3 (count (rrule/timestamps "20240101T000000" "FREQ=DAILY;COUNT=3")))))

;; --- properties ------------------------------------------------------------

(def gen-start
  (gen/let [y (gen/choose 1000 2100) m (gen/choose 1 12) d (gen/choose 1 28)
            h (gen/choose 0 23) mi (gen/choose 0 59) s (gen/choose 0 59)]
    (format "%04d%02d%02dT%02d%02d%02d" y m d h mi s)))

(def gen-rule
  (gen/let [freq (gen/elements ["YEARLY" "MONTHLY" "WEEKLY" "DAILY"])
            interval (gen/choose 1 5)
            days (gen/set (gen/elements ["MO" "TU" "WE" "TH" "FR" "SA" "SU"]))
            use-days gen/boolean
            setpos (gen/elements [nil "1" "-1" "2"])]
    (str "FREQ=" freq ";INTERVAL=" interval
         (when (and use-days (seq days)) (str ";BYDAY=" (str/join "," days)))
         (when setpos (str ";BYSETPOS=" setpos)))))

(defspec output-is-increasing-and-bounded 200
  (prop/for-all [start gen-start rule gen-rule n (gen/choose 1 30)]
    (let [out (rrule/occurrence-strings start rule {:limit n})]
      (and (<= (count out) n)
           (every? #(>= (compare % start) 0) out)
           (every? neg? (map compare out (rest out)))
           (every? #(= (subs start 8) (subs % 8)) out)))))

(defspec daily-matches-day-arithmetic 100
  (prop/for-all [start gen-start interval (gen/choose 1 100)]
    (let [out (rrule/timestamps start (str "FREQ=DAILY;INTERVAL=" interval) {:limit 5})]
      (= (map #(* % 86400 interval) [0 1 2 3 4])
         (map #(- % (first out)) out)))))
