(ns toml.datetime-test
  (:require [clojure.test :refer [deftest is are]]
            [toml.data :as d]
            [toml.datetime :as dt]))

(defn- scan [s] (when-let [[sc end] (dt/scan s 0)] [(:type sc) (:value sc) end]))

(deftest canonical-forms
  (are [in out] (= out (scan in))
    "1979-05-27" [:date-local "1979-05-27" 10]
    "07:32:00" [:time-local "07:32:00" 8]
    "07:32:00.500" [:time-local "07:32:00.5" 12]
    "07:32:00.000" [:time-local "07:32:00" 12]
    "1979-05-27T07:32:00" [:datetime-local "1979-05-27T07:32:00" 19]
    "1979-05-27t07:32:00" [:datetime-local "1979-05-27T07:32:00" 19]
    "1979-05-27 07:32:00" [:datetime-local "1979-05-27T07:32:00" 19]
    "1987-07-05 17:45:00z" [:datetime "1987-07-05T17:45:00Z" 20]
    "1979-05-27T07:32:00-00:00" [:datetime "1979-05-27T07:32:00Z" 25]
    "1979-05-27T07:32:00+00:00" [:datetime "1979-05-27T07:32:00Z" 25]
    "1979-05-27T00:32:00.999999-07:00" [:datetime "1979-05-27T00:32:00.999999-07:00" 32]))

(deftest space-needs-a-complete-time
  (is (= [:date-local "1979-05-27" 10] (scan "1979-05-27 # comment")))
  (is (= [:date-local "1979-05-27" 10] (scan "1979-05-27 07:32"))))

(deftest invalid
  (doseq [s ["1979-02-30" "1979-13-01" "1979-00-10" "1979-5-27" "0000-01-01"
             "1979-05-27T" "1979-05-27T25:00:00" "07:32" "07:60:00" "07:32:60"
             "07:32:00." "1979-05-27T07:32:00+24:00" "1979-05-27T07:32:00+01"
             "\u0661\u0669\u0667\u0669-05-27"]]
    (is (nil? (scan s)) s)))

(deftest leap-years
  (is (some? (scan "2000-02-29")))
  (is (some? (scan "2024-02-29")))
  (is (nil? (scan "1900-02-29")))
  (is (nil? (scan "2023-02-29"))))
