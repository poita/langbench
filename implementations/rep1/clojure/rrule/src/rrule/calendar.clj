(ns rrule.calendar
  "Proleptic-Gregorian calendar arithmetic on integer day numbers.

  A *day number* is the count of days since 1970-01-01 (which is day 0).
  Every conversion is closed-form (O(1)) and uses the 400-year cycle; there
  is no iteration over years or months.

  Weekdays are numbered MO=0 ... SU=6.

  Nothing here depends on any date/time facility of the JVM."
  (:refer-clojure :exclude [mod]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(defn mod
  "Floored modulus of longs (result has the sign of `d`)."
  ^long [^long n ^long d]
  (Math/floorMod n d))

(defn fdiv
  "Floored division of longs."
  ^long [^long n ^long d]
  (Math/floorDiv n d))

(defn leap-year?
  "True if `y` is a leap year in the proleptic Gregorian calendar."
  [^long y]
  (and (zero? (rem y 4))
       (or (not (zero? (rem y 100)))
           (zero? (rem y 400)))))

(defn days-in-year
  "Number of days in year `y` (365 or 366)."
  ^long [^long y]
  (if (leap-year? y) 366 365))

(def ^:private ^"[J" month-lengths
  (long-array [31 28 31 30 31 30 31 31 30 31 30 31]))

(defn days-in-month
  "Number of days in month `m` (1-12) of year `y`."
  ^long [^long y ^long m]
  (if (and (== m 2) (leap-year? y))
    29
    (aget month-lengths (dec m))))

(defn days-from-civil
  "Day number of the date `y`-`m`-`d` (month 1-12, day 1-31)."
  ^long [^long y ^long m ^long d]
  (let [y   (if (<= m 2) (dec y) y)
        era (fdiv y 400)
        yoe (- y (* era 400))
        mp  (mod (+ m 9) 12)
        doy (+ (quot (+ (* 153 mp) 2) 5) (dec d))
        doe (+ (* yoe 365) (quot yoe 4) (- (quot yoe 100)) doy)]
    (+ (* era 146097) doe -719468)))

(defn civil-from-days-packed
  "Date of day number `dn`, packed into one long as `y*512 + m*32 + d`.
  Use [[packed-year]], [[packed-month]] and [[packed-day]] to unpack."
  ^long [^long dn]
  (let [z   (+ dn 719468)
        era (fdiv z 146097)
        doe (- z (* era 146097))
        yoe (quot (- doe (quot doe 1460) (- (quot doe 36524)) (quot doe 146096))
                  365)
        y   (+ yoe (* era 400))
        doy (- doe (- (+ (* 365 yoe) (quot yoe 4)) (quot yoe 100)))
        mp  (quot (+ (* 5 doy) 2) 153)
        d   (inc (- doy (quot (+ (* 153 mp) 2) 5)))
        m   (if (< mp 10) (+ mp 3) (- mp 9))
        y   (if (<= m 2) (inc y) y)]
    (+ (* y 512) (* m 32) d)))

(defn packed-year  ^long [^long p] (bit-shift-right p 9))
(defn packed-month ^long [^long p] (bit-and (bit-shift-right p 5) 15))
(defn packed-day   ^long [^long p] (bit-and p 31))

(defn civil-from-days
  "Date `[year month day]` of day number `dn`."
  [^long dn]
  (let [p (civil-from-days-packed dn)]
    [(packed-year p) (packed-month p) (packed-day p)]))

(defn weekday
  "Weekday of day number `dn`: MO=0 ... SU=6.  (1970-01-01 is a Thursday.)"
  ^long [^long dn]
  (mod (+ dn 3) 7))

;; ---------------------------------------------------------------------------
;; Week numbering (RFC 5545 style: week 1 is the first week with >= 4 days
;; in the year; weeks start on `wkst`).

(defn week1-start
  "0-based day-of-year index (possibly negative, i.e. in the previous
  December) of the first day of week 1 of year `y` when weeks start on
  weekday `wkst`."
  ^long [^long y ^long wkst]
  (let [first-wd (weekday (days-from-civil y 1 1))
        f        (mod (- wkst first-wd) 7)]
    (if (< f 4) f (- f 7))))

(defn weeks-in-year
  "Number of weeks (52 or 53) in year `y` when weeks start on `wkst`."
  ^long [^long y ^long wkst]
  (let [l (- (days-in-year y) (week1-start y wkst))]
    (+ (quot l 7) (if (>= (rem l 7) 4) 1 0))))
