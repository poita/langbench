(ns rrule.parse-test
  (:require [clojure.test :refer [deftest is testing]]
            [rrule.datetime :as dt]
            [rrule.parse :as parse]
            [rrule.rule :as rule]))

(deftest parse-rule-parts
  (let [r (parse/parse-rule "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR,MO;BYSETPOS=-1,2;WKST=SU;COUNT=5")]
    (is (= :monthly (:freq r)))
    (is (= 2 (:interval r)))
    (is (= 5 (:count r)))
    (is (= 6 (:wkst r)))
    (is (= [[-1 4] [nil 0]] (:byday r)))
    (is (= [-1 2] (:bysetpos r)))
    (is (nil? (:until r)))
    (is (nil? (:bymonth r)))))

(deftest parse-rule-defaults
  (let [r (parse/parse-rule "FREQ=DAILY;UNTIL=20240101T000000")]
    (is (= 1 (:interval r)))
    (is (= 0 (:wkst r)))
    (is (= (dt/parse-timestamp "20240101T000000") (:until r)))))

(deftest parse-rule-errors
  (is (thrown? clojure.lang.ExceptionInfo (parse/parse-rule "COUNT=3")))
  (is (thrown? clojure.lang.ExceptionInfo (parse/parse-rule "FREQ=HOURLY")))
  (is (thrown? clojure.lang.ExceptionInfo (parse/parse-rule "FREQ=DAILY;BYDAY=XX"))))

(deftest parse-line
  (let [{:keys [dtstart rule limit]} (parse/parse-line "19970902T090000 FREQ=DAILY;COUNT=3 100")]
    (is (= (dt/parse-timestamp "19970902T090000") dtstart))
    (is (= :daily (:freq rule)))
    (is (= 100 limit)))
  (is (thrown? clojure.lang.ExceptionInfo (parse/parse-line "19970902T090000 FREQ=DAILY"))))

(deftest defaults-from-dtstart
  (let [ts (dt/parse-timestamp "20240315T100000")        ; a Friday
        with #(rule/with-defaults (parse/parse-rule %) ts)]
    (is (= {:bymonth [3] :bymonthday [15]}
           (select-keys (with "FREQ=YEARLY") [:bymonth :bymonthday])))
    (is (= [7] (:bymonth (with "FREQ=YEARLY;BYMONTH=7"))))
    (is (= [15] (:bymonthday (with "FREQ=MONTHLY"))))
    (is (= [[nil 4]] (:byday (with "FREQ=WEEKLY"))))
    (is (nil? (:byday (with "FREQ=DAILY"))))
    (testing "no defaults when an explicit BY part is present"
      (is (nil? (:bymonthday (with "FREQ=MONTHLY;BYDAY=MO")))))))
