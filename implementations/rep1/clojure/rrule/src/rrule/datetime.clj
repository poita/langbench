(ns rrule.datetime
  "Floating (zone-less) date-times.

  Two representations are used:

  * a *datetime map* `{:year :month :day :hour :minute :second}` for the
    public API, and
  * a *timestamp*: a long counting seconds since 1970-01-01T00:00:00 with
    no time zone, used internally because it compares chronologically with
    plain `<`."
  (:require [rrule.calendar :as cal]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def ^:const seconds-per-day 86400)

(defn timestamp
  "Timestamp (seconds since 1970-01-01T00:00:00) of a datetime map."
  ^long [{:keys [year month day hour minute second]}]
  (+ (* (cal/days-from-civil year month day) seconds-per-day)
     (* (long hour) 3600) (* (long minute) 60) (long second)))

(defn timestamp->datetime
  "Datetime map of a timestamp."
  [^long ts]
  (let [dn  (cal/fdiv ts seconds-per-day)
        tod (cal/mod ts seconds-per-day)
        [y m d] (cal/civil-from-days dn)]
    {:year y :month m :day d
     :hour (quot tod 3600) :minute (quot (rem tod 3600) 60) :second (rem tod 60)}))

(defn- digits
  "Parse the `len` ASCII digits of `s` starting at `start`."
  ^long [^String s ^long start ^long len]
  (loop [i start, acc 0]
    (if (< i (+ start len))
      (let [c (long (int (.charAt s (int i))))]
        (when-not (<= 48 c 57)
          (throw (ex-info (str "Invalid date-time: " (pr-str s)) {:value s})))
        (recur (inc i) (+ (* acc 10) (- c 48))))
      acc)))

(defn parse-timestamp
  "Parse `YYYYMMDDTHHMMSS` into a timestamp.  Throws `ex-info` when the
  text is malformed or names an impossible date or time."
  ^long [^String s]
  (when-not (and (== 15 (.length s)) (== 84 (int (.charAt s 8))))
    (throw (ex-info (str "Invalid date-time: " (pr-str s)) {:value s})))
  (let [y (digits s 0 4), mo (digits s 4 2), d (digits s 6 2)
        h (digits s 9 2), mi (digits s 11 2), sec (digits s 13 2)]
    (when-not (and (<= 1 mo 12) (<= 1 d (cal/days-in-month y mo))
                   (<= h 23) (<= mi 59) (<= sec 59))
      (throw (ex-info (str "Invalid date-time: " (pr-str s)) {:value s})))
    (+ (* (cal/days-from-civil y mo d) seconds-per-day)
       (* h 3600) (* mi 60) sec)))

(defn parse-datetime
  "Parse `YYYYMMDDTHHMMSS` into a datetime map."
  [^String s]
  (timestamp->datetime (parse-timestamp s)))

(defn- pad!
  [^StringBuilder sb ^long v ^long width]
  (loop [p (long (Math/pow 10 (dec width)))]
    (when (and (> p 1) (< v p))
      (.append sb \0)
      (recur (quot p 10))))
  (.append sb v))

(defn append-timestamp!
  "Append the `YYYYMMDDTHHMMSS` text of timestamp `ts` to StringBuilder `sb`."
  [^StringBuilder sb ^long ts]
  (let [dn  (cal/fdiv ts seconds-per-day)
        tod (cal/mod ts seconds-per-day)
        p   (cal/civil-from-days-packed dn)]
    (pad! sb (cal/packed-year p) 4)
    (pad! sb (cal/packed-month p) 2)
    (pad! sb (cal/packed-day p) 2)
    (.append sb \T)
    (pad! sb (quot tod 3600) 2)
    (pad! sb (quot (rem tod 3600) 60) 2)
    (pad! sb (rem tod 60) 2)
    sb))

(defn format-timestamp
  "`YYYYMMDDTHHMMSS` text of a timestamp."
  [^long ts]
  (str (append-timestamp! (StringBuilder. 15) ts)))

(defn format-datetime
  "`YYYYMMDDTHHMMSS` text of a datetime map."
  [dt]
  (format-timestamp (timestamp dt)))
