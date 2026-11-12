(ns rrule.datetime-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [rrule.datetime :as dt]))

(deftest parse-and-format
  (is (= {:year 1997 :month 9 :day 2 :hour 9 :minute 0 :second 0}
         (dt/parse-datetime "19970902T090000")))
  (is (= "99991231T235959" (dt/format-timestamp (dt/parse-timestamp "99991231T235959")))))

(deftest formatting-pads
  (is (= "10000101T000507"
         (dt/format-datetime {:year 1000 :month 1 :day 1 :hour 0 :minute 5 :second 7}))))

(deftest rejects-bad-input
  (is (thrown? clojure.lang.ExceptionInfo (dt/parse-timestamp "20230230T000000")))
  (is (thrown? clojure.lang.ExceptionInfo (dt/parse-timestamp "20230201T240000")))
  (is (thrown? clojure.lang.ExceptionInfo (dt/parse-timestamp "2023-02-01")))
  (is (thrown? clojure.lang.ExceptionInfo (dt/parse-timestamp "20230201X000000"))))

(deftest timestamps-order-chronologically
  (is (< (dt/parse-timestamp "20240229T235959") (dt/parse-timestamp "20240301T000000"))))

(defspec text-roundtrip 300
  (prop/for-all [y (gen/choose 1000 9999) m (gen/choose 1 12) d (gen/choose 1 28)
                 h (gen/choose 0 23) mi (gen/choose 0 59) s (gen/choose 0 59)]
    (let [text (format "%04d%02d%02dT%02d%02d%02d" y m d h mi s)]
      (= text (dt/format-timestamp (dt/parse-timestamp text))))))
