(ns rrule.core
  "Public API of the rrule library: expansion of RFC 5545 recurrence rules
  (`FREQ` = YEARLY / MONTHLY / WEEKLY / DAILY) with the semantics of
  python-dateutil's `rrule`.

  Date-times are *floating*: there are no time zones.  They are represented
  as maps `{:year :month :day :hour :minute :second}` or as
  `YYYYMMDDTHHMMSS` strings; both are accepted wherever a date-time is
  expected.  All calendar arithmetic is implemented in [[rrule.calendar]].

  Example:

      (occurrences \"19970902T090000\" \"FREQ=MONTHLY;BYDAY=-1FR;COUNT=3\")
      ;=> [{:year 1997 :month 9 :day 26 ...} ...]

      (occurrence-strings \"20240229T120000\" \"FREQ=YEARLY\" {:limit 3})
      ;=> [\"20240229T120000\" \"20280229T120000\" \"20320229T120000\"]"
  (:require [rrule.datetime :as dt]
            [rrule.expand :as expand]
            [rrule.parse :as parse]
            [rrule.rule :as rule]))

(set! *warn-on-reflection* true)

(defn parse-rule
  "Parse an RRULE value (e.g. `\"FREQ=WEEKLY;BYDAY=MO,WE\"`) into a rule map;
  see [[rrule.parse/parse-rule]] for the shape.  Throws `ex-info` on
  malformed input."
  [s]
  (parse/parse-rule s))

(defn- ->timestamp ^long [x]
  (if (string? x) (dt/parse-timestamp x) (dt/timestamp x)))

(defn timestamps
  "Occurrence timestamps (seconds since 1970-01-01T00:00:00, no zone) of
  `rule` from `dtstart`, in increasing order.  `rule` is an RRULE string or a
  rule map from [[parse-rule]]; `dtstart` is a string or datetime map.

  Options: `:limit` — maximum number of occurrences (default: unlimited,
  i.e. bounded only by COUNT / UNTIL and the year 9999)."
  ([dtstart rule] (timestamps dtstart rule nil))
  ([dtstart rule {:keys [limit]}]
   (let [ts (->timestamp dtstart)
         r  (if (string? rule) (parse-rule rule) rule)]
     (expand/expand (rule/with-defaults r ts) ts limit))))

(defn occurrences
  "Occurrences of `rule` from `dtstart` as a vector of datetime maps.
  Accepts the same arguments and options as [[timestamps]]."
  ([dtstart rule] (occurrences dtstart rule nil))
  ([dtstart rule opts]
   (mapv dt/timestamp->datetime (timestamps dtstart rule opts))))

(defn occurrence-strings
  "Occurrences of `rule` from `dtstart` as `YYYYMMDDTHHMMSS` strings.
  Accepts the same arguments and options as [[timestamps]]."
  ([dtstart rule] (occurrence-strings dtstart rule nil))
  ([dtstart rule opts]
   (mapv dt/format-timestamp (timestamps dtstart rule opts))))

(defn expand-line
  "Process one input line `<DTSTART> <RRULE> <N>` and return the output line
  (without the line terminator): the first N occurrences separated by single
  spaces."
  ^String [^String line]
  (let [{:keys [dtstart rule limit]} (parse/parse-line line)
        occ (expand/expand (rule/with-defaults rule dtstart) dtstart limit)
        sb  (StringBuilder.)]
    (doseq [ts occ]
      (when (pos? (.length sb)) (.append sb \space))
      (dt/append-timestamp! sb ts))
    (str sb)))
