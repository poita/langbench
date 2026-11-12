(ns rrule.parse
  "Parsing of RRULE values and of the `<DTSTART> <RRULE> <N>` input lines.

  A parsed rule is a plain map (see [[parse-rule]]); no defaults derived
  from DTSTART are applied here, see [[rrule.rule/with-defaults]]."
  (:require [clojure.string :as str]
            [rrule.datetime :as dt]))

(set! *warn-on-reflection* true)

(def weekday-codes
  "Two-letter weekday code -> weekday number (MO=0 ... SU=6)."
  {"MO" 0 "TU" 1 "WE" 2 "TH" 3 "FR" 4 "SA" 5 "SU" 6})

(def ^:private freqs
  {"YEARLY" :yearly "MONTHLY" :monthly "WEEKLY" :weekly "DAILY" :daily})

(defn- fail [msg value]
  (throw (ex-info (str msg ": " (pr-str value)) {:value value})))

(defn- parse-int
  ^long [^String s]
  (try (Long/parseLong s)
       (catch NumberFormatException _ (fail "Invalid integer" s))))

(defn- int-list [^String s]
  (mapv parse-int (str/split s #",")))

(defn- parse-byday-item
  "`MO`, `2MO` or `-1FR` -> `[ordinal-or-nil weekday]`."
  [^String s]
  (let [n    (.length s)
        code (when (>= n 2) (subs s (- n 2)))
        wd   (get weekday-codes code)]
    (when (nil? wd) (fail "Invalid BYDAY value" s))
    (if (== n 2)
      [nil wd]
      [(parse-int (subs s 0 (- n 2))) wd])))

(defn parse-rule
  "Parse an RRULE value such as `FREQ=MONTHLY;BYDAY=-1FR;COUNT=10`.

  Returns a map with the keys

    :freq       :yearly | :monthly | :weekly | :daily
    :interval   long (default 1)
    :count      long or nil
    :until      timestamp (see [[rrule.datetime]]) or nil
    :wkst       weekday number (default 0, Monday)
    :bymonth :bymonthday :byyearday :byweekno :bysetpos
                vectors of longs, or nil when the part is absent
    :byday      vector of `[ordinal-or-nil weekday]`, or nil

  Throws `ex-info` for a malformed rule or one without `FREQ`."
  [^String s]
  (let [parts (into {}
                    (map (fn [part]
                           (let [i (.indexOf ^String part "=")]
                             (when (neg? i) (fail "Invalid rule part" part))
                             [(subs part 0 i) (subs part (inc i))])))
                    (str/split s #";"))
        get-int-list (fn [k] (some-> (get parts k) int-list))
        freq (get freqs (get parts "FREQ"))]
    (when-not freq (fail "Missing or unknown FREQ" s))
    {:freq       freq
     :interval   (if-let [v (get parts "INTERVAL")] (parse-int v) 1)
     :count      (some-> (get parts "COUNT") parse-int)
     :until      (some-> (get parts "UNTIL") dt/parse-timestamp)
     :wkst       (if-let [v (get parts "WKST")]
                   (or (weekday-codes v) (fail "Invalid WKST" v))
                   0)
     :bymonth    (get-int-list "BYMONTH")
     :bymonthday (get-int-list "BYMONTHDAY")
     :byyearday  (get-int-list "BYYEARDAY")
     :byweekno   (get-int-list "BYWEEKNO")
     :byday      (some->> (get parts "BYDAY")
                          (#(str/split ^String % #","))
                          (mapv parse-byday-item))
     :bysetpos   (get-int-list "BYSETPOS")}))

(defn parse-line
  "Parse an input line `<DTSTART> <RRULE> <N>` into
  `{:dtstart timestamp, :rule rule-map, :limit long}`."
  [^String line]
  (let [fields (str/split line #" ")]
    (when-not (== 3 (count fields)) (fail "Invalid input line" line))
    (let [[start rule n] fields]
      {:dtstart (dt/parse-timestamp start)
       :rule    (parse-rule rule)
       :limit   (parse-int n)})))
