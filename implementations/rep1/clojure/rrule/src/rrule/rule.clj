(ns rrule.rule
  "Rule normalisation: the defaults that a rule derives from its DTSTART."
  (:require [rrule.calendar :as cal]
            [rrule.datetime :as dt]))

(set! *warn-on-reflection* true)

(defn with-defaults
  "Apply SPEC §1: when none of BYMONTHDAY, BYYEARDAY, BYWEEKNO, BYDAY is
  present, fill in BYMONTH / BYMONTHDAY / BYDAY from the DTSTART timestamp
  `dtstart`, depending on the frequency."
  [rule ^long dtstart]
  (if (some rule [:bymonthday :byyearday :byweekno :byday])
    rule
    (let [dn (cal/fdiv dtstart dt/seconds-per-day)
          [_ m d] (cal/civil-from-days dn)]
      (case (:freq rule)
        :yearly  (assoc rule
                        :bymonth (or (:bymonth rule) [m])
                        :bymonthday [d])
        :monthly (assoc rule :bymonthday [d])
        :weekly  (assoc rule :byday [[nil (cal/weekday dn)]])
        :daily   rule))))
