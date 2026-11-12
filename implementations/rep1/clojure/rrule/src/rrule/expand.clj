(ns rrule.expand
  "The expansion engine: turns a normalised rule (see
  [[rrule.rule/with-defaults]]) and a DTSTART timestamp into occurrences.

  The rule is evaluated period by period (SPEC §2).  Every period supplies
  its candidate days, each of which is tested against every filter (§3-§5)
  in O(1); BYSETPOS then selects among the kept days (§6) and the survivors
  are emitted (§7).  No rule-specific shortcuts are taken: every period up
  to a limit, the year-9999 bound or the UNTIL shortcut is enumerated."
  (:require [rrule.calendar :as cal]
            [rrule.datetime :as dt])
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def ^:private ^:const max-day
  "Day number of 9999-12-31: no period may start after it."
  (cal/days-from-civil 9999 12 31))

(defn- offset-set
  "Boolean array `a` with `(aget a (+ v offset))` true for each `v` in `vals`;
  nil when `vals` is nil (the filter is absent)."
  ^booleans [vals ^long offset ^long size]
  (when vals
    (let [a (boolean-array size)]
      (doseq [v vals] (aset a (int (+ (long v) offset)) true))
      a)))

(defn- set-mask
  "Bit mask with bit `v` set for each `v` in `vals`."
  ^long [vals]
  (reduce (fn [^long acc v] (bit-or acc (bit-shift-left 1 (long v)))) 0 vals))

(defn- mark-ordinals!
  "Mark in `marks` (indexed by day offset from the period start) the days
  designated by the ordinal BYDAY codes `ords` (a seq of `[n weekday]`)
  within the range of `rlen` days starting at offset `rs`, whose first day
  has weekday `wd0`."
  [^booleans marks ords rs rlen wd0]
  (let [rs (long rs), rlen (long rlen), wd0 (long wd0)
        last-off (+ rs rlen -1)
        last-wd  (cal/mod (+ wd0 rlen -1) 7)]
    (doseq [[n wd] ords]
      (let [n (long n), wd (long wd)]
       (if (pos? n)
        (let [idx (+ rs (cal/mod (- wd wd0) 7) (* 7 (dec n)))]
          (when (<= idx last-off) (aset marks (int idx) true)))
        (let [idx (+ (- last-off (cal/mod (- last-wd wd) 7)) (* 7 (inc n)))]
          (when (>= idx rs) (aset marks (int idx) true))))))))

(defn expand
  "Expand `rule` from the DTSTART timestamp `dtstart`; returns a vector of
  occurrence timestamps in increasing order.

  `rule` must already carry the DTSTART defaults.  `limit` is the maximum
  number of occurrences to return (a long), or nil for no limit other than
  the rule's own COUNT / UNTIL and the year-9999 bound."
  [rule ^long dtstart limit]
  (let [freq       (case (:freq rule) :yearly 0 :monthly 1 :weekly 2 :daily 3)
        interval   (long (:interval rule))
        wkst       (long (:wkst rule))
        dt-day     (cal/fdiv dtstart dt/seconds-per-day)
        tod        (cal/mod dtstart dt/seconds-per-day)
        until      (long (or (:until rule) Long/MAX_VALUE))
        max-out    (let [a (long (or limit Long/MAX_VALUE))
                         b (long (or (:count rule) Long/MAX_VALUE))]
                     (if (< a b) a b))
        bymonth    (long (if-let [v (:bymonth rule)] (set-mask v) -1))
        ^"[Z" bymd       (offset-set (:bymonthday rule) 31 63)
        ^"[Z" byyd       (offset-set (:byyearday rule) 366 733)
        ^"[Z" bywn       (offset-set (:byweekno rule) 53 107)
        ^"[Z" setpos     (offset-set (:bysetpos rule) 366 733)
        byday      (:byday rule)
        ordinal?   (boolean (some first byday))
        ords       (when ordinal? byday)
        wdmask     (long (if (and byday (not ordinal?))
                           (set-mask (map second byday))
                           -1))
        bymonths   (vec (sort (:bymonth rule)))
        ;; ordinal ranges: a month each (MONTHLY / YEARLY with BYMONTH) or the year
        ord-months? (and ordinal? (or (== freq 1) (seq bymonths)))
        y0         (cal/packed-year (cal/civil-from-days-packed dt-day))
        m0         (cal/packed-month (cal/civil-from-days-packed dt-day))
        week-a     (- dt-day (cal/mod (- (cal/weekday dt-day) wkst) 7))
        ^longs buf        (long-array 372)
        ^"[Z" marks      (boolean-array 372)
        out        (java.util.ArrayList.)]
    (loop [k 0]
      (let [;; --- period start (day number) and length -----------------
            ;; For YEARLY/MONTHLY the year/month are derived as well.
            total  (+ (dec m0) (* k interval))
            py     (long (case freq
                           0 (+ y0 (* k interval))
                           1 (+ y0 (cal/fdiv total 12))
                           0))
            pm     (if (== freq 1) (inc (cal/mod total 12)) 1)
            start  (long (case freq
                     0 (cal/days-from-civil py 1 1)
                     1 (cal/days-from-civil py pm 1)
                     2 (if (zero? k) dt-day (+ week-a (* 7 k interval)))
                     3 (+ dt-day (* k interval))))
            len    (long (case freq
                     0 (cal/days-in-year py)
                     1 (cal/days-in-month py pm)
                     2 (if (zero? k) (- (+ week-a 7) dt-day) 7)
                     3 1))
            ended? (if (<= freq 1)
                     (> py 9999)
                     (> start max-day))]
        (if (or ended? (> (+ (* start dt/seconds-per-day) tod) until))
          nil
          (let [;; --- per-period data for O(1) per-day filters ----------
                wd-start (cal/weekday start)
                ylen     (if (zero? freq) len 0)
                ;; week numbering (YEARLY + BYWEEKNO only)
                s        (if bywn (cal/week1-start py wkst) 0)
                wks      (if bywn (cal/weeks-in-year py wkst) 0)
                prev-p   (if bywn
                           (if (neg? (cal/week1-start (dec py) wkst))
                             (cal/weeks-in-year (dec py) wkst)
                             (+ 52 (if (>= (rem (- ylen s) 7) 4) 1 0)))
                           0)
                _ (when ordinal?
                    (Arrays/fill marks 0 (int len) false)
                    (if ord-months?
                      (if (== freq 1)
                        (mark-ordinals! marks ords 0 len wd-start)
                        (doseq [m bymonths]
                          (let [m  (long m)
                                ms (- (cal/days-from-civil py m 1) start)]
                            (mark-ordinals! marks ords ms (cal/days-in-month py m)
                                            (cal/weekday (+ start ms))))))
                      (mark-ordinals! marks ords 0 len wd-start)))
                ;; --- filter the candidate days ---------------------------
                cnt
                (long
                 (loop [j 0, c 0]
                  (if (< j len)
                    (let [dn (+ start j)
                          p  (cal/civil-from-days-packed dn)
                          y  (cal/packed-year p)
                          m  (cal/packed-month p)
                          d  (cal/packed-day p)]
                      (if (and (not (zero? (bit-and bymonth (bit-shift-left 1 m))))
                               (or (nil? bymd)
                                   (let [dim (cal/days-in-month y m)]
                                     (or (aget bymd (int (+ d 31)))
                                         (aget bymd (int (+ (- d dim 1) 31))))))
                               (or (nil? byyd)
                                   (aget byyd (int (+ (inc j) 366)))
                                   (aget byyd (int (+ (- (inc j) ylen 1) 366))))
                               (or (nil? bywn)
                                   (cond
                                     (< j s) (or (aget bywn 52)
                                                 (aget bywn (int (+ prev-p 53))))
                                     :else
                                     (let [w (inc (quot (- j s) 7))]
                                       (if (<= w wks)
                                         (or (aget bywn (int (+ w 53)))
                                             (aget bywn (int (+ (- w wks 1) 53))))
                                         (aget bywn 54)))))
                               (or (== wdmask -1)
                                   (not (zero? (bit-and wdmask
                                                        (bit-shift-left 1 (cal/weekday dn))))))
                               (or (not ordinal?) (aget marks (int j))))
                        (do (aset buf (int c) dn)
                            (recur (inc j) (inc c)))
                        (recur (inc j) c)))
                    c)))
                ;; --- select (BYSETPOS) and emit ---------------------------
                stop?
                (loop [i 0]
                  (if (< i cnt)
                    (if (or (nil? setpos)
                            (aget setpos (int (+ (inc i) 366)))
                            (aget setpos (int (+ (- i cnt) 366))))
                      (let [ts (+ (* (aget buf (int i)) dt/seconds-per-day) tod)]
                        (cond
                          (> ts until)    true
                          (< ts dtstart)  (recur (inc i))
                          :else
                          (do (.add out ts)
                              (if (>= (.size out) max-out)
                                true
                                (recur (inc i))))))
                      (recur (inc i)))
                    false))]
            (when-not stop?
              (recur (inc k)))))))
    (vec out)))
