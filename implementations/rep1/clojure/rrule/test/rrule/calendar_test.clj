(ns rrule.calendar-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [rrule.calendar :as cal]))

(deftest leap-years
  (is (cal/leap-year? 2024))
  (is (cal/leap-year? 2000))
  (is (not (cal/leap-year? 1900)))
  (is (not (cal/leap-year? 2023)))
  (is (= 366 (cal/days-in-year 2000)))
  (is (= 365 (cal/days-in-year 2100))))

(deftest month-lengths
  (is (= [31 29 31 30 31 30 31 31 30 31 30 31]
         (mapv #(cal/days-in-month 2024 %) (range 1 13))))
  (is (= 28 (cal/days-in-month 1900 2))))

(deftest anchors
  (testing "day 0 is 1970-01-01, a Thursday"
    (is (= 0 (cal/days-from-civil 1970 1 1)))
    (is (= 3 (cal/weekday 0))))
  (testing "2000-01-01 is a Saturday, 0001-01-01 a Monday"
    (is (= 5 (cal/weekday (cal/days-from-civil 2000 1 1))))
    (is (= 0 (cal/weekday (cal/days-from-civil 1 1 1)))))
  (testing "extremes"
    (is (= [9999 12 31] (cal/civil-from-days (cal/days-from-civil 9999 12 31))))
    (is (= [1000 1 1] (cal/civil-from-days (cal/days-from-civil 1000 1 1))))))

(deftest week-numbering
  (testing "WKST=MO"
    (is (= 2 (cal/week1-start 2011 0)))     ; Monday 3 January 2011
    (is (= -3 (cal/week1-start 2015 0)))    ; Monday 29 December 2014
    (is (= 53 (cal/weeks-in-year 2015 0)))
    (is (= 52 (cal/weeks-in-year 2011 0)))
    (is (= 53 (cal/weeks-in-year 2020 0)))))

(def gen-date
  (gen/let [y (gen/choose 1 9999)
            m (gen/choose 1 12)
            d (gen/choose 1 28)]
    [y m d]))

(defspec civil-roundtrip 500
  (prop/for-all [[y m d] gen-date]
    (= [y m d] (cal/civil-from-days (cal/days-from-civil y m d)))))

(defspec consecutive-days 500
  (prop/for-all [dn (gen/choose -700000 3000000)]
    (let [[y m d] (cal/civil-from-days dn)
          [y2 m2 d2] (cal/civil-from-days (inc dn))]
      (and (= (cal/days-from-civil y m d) dn)
           (= (cal/mod (inc (cal/weekday dn)) 7) (cal/weekday (inc dn)))
           (if (< d (cal/days-in-month y m))
             (= [y m (inc d)] [y2 m2 d2])
             (and (= d2 1)
                  (= (if (= m 12) [(inc y) 1] [y (inc m)]) [y2 m2])))))))

(defspec year-lengths-agree 200
  (prop/for-all [y (gen/choose 1 9998)]
    (= (cal/days-in-year y)
       (- (cal/days-from-civil (inc y) 1 1) (cal/days-from-civil y 1 1)))))

(defspec week-counts 200
  (prop/for-all [y (gen/choose 1000 9999) wkst (gen/choose 0 6)]
    (contains? #{52 53} (cal/weeks-in-year y wkst))))
