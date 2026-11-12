(ns mime.date-test
  (:require [clojure.test :refer [deftest are is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [mime.date :as d]))

(deftest date-examples
  (are [raw epoch utc offset] (= {:epoch epoch :utc utc :offset offset} (d/parse raw))
    "Sun, 29 Feb 2004 22:03:22 -0800" 1078121002 "2004-03-01T06:03:22Z" "-0800"
    "3 Jan 70 00:00:00 GMT"           172800     "1970-01-03T00:00:00Z" "+0000"
    "Tue, 1 Jan 2036 00:00:60 +0000"  2082758460 "2036-01-01T00:01:00Z" "+0000"
    "Mon, 3 Mar 1969 12:00 (GMT) -0500" -26204400 "1969-03-03T17:00:00Z" "-0500"
    "Sun, 07 Mar 2004 15:21:26 -0000" 1078672886 "2004-03-07T15:21:26Z" "+0000"
    "1 Jan 2000 00:00:00 +2359"       946598460  "1999-12-31T00:01:00Z" "+2359"
    "1 Jan 2000 00:00:00 +9999"       946322460  "1999-12-27T19:21:00Z" "+10039"))

(deftest invalid-dates
  (are [raw] (nil? (d/parse raw))
    "not a date" "" "30 Feb 2001 00:00:00" "1 Jan 2000 24:00" "1 Foo 2000 00:00"
    "1 Jan 0000 00:00"))

(deftest unknown-zone-is-utc
  (is (= "+0000" (:offset (d/parse "1 Jan 2000 00:00:00 XYZ"))))
  (is (= "-0500" (:offset (d/parse "1 Jan 2000 00:00:00 est")))))

(defspec civil-round-trip 300
  (prop/for-all [days (gen/choose -800000 800000)]
    (let [[y m dd] (d/civil-from-days days)]
      (= days (d/days-from-civil y m dd)))))
