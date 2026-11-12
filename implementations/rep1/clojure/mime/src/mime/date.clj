(ns mime.date
  "Date header parsing with closed-form calendar arithmetic."
  (:require [clojure.string :as str]
            [mime.text :as text]))

(set! *warn-on-reflection* true)

(def ^:private days-of-week #{"mon" "tue" "wed" "thu" "fri" "sat" "sun"})

(def ^:private months
  {"jan" 1 "feb" 2 "mar" 3 "apr" 4 "may" 5 "jun" 6
   "jul" 7 "aug" 8 "sep" 9 "oct" 10 "nov" 11 "dec" 12})

(def ^:private zones
  {"ut" 0 "gmt" 0 "z" 0 "est" -300 "edt" -240 "cst" -360 "cdt" -300
   "mst" -420 "mdt" -360 "pst" -480 "pdt" -420})

(defn days-from-civil
  "Number of days from 1970-01-01 to the proleptic Gregorian date y-m-d."
  ^long [^long y ^long m ^long d]
  (let [y (if (<= m 2) (dec y) y)
        era (Math/floorDiv y 400)
        yoe (- y (* era 400))
        doy (+ (quot (+ (* 153 (if (> m 2) (- m 3) (+ m 9))) 2) 5) (dec d))
        doe (+ (* yoe 365) (quot yoe 4) (- (quot yoe 100)) doy)]
    (+ (* era 146097) doe -719468)))

(defn civil-from-days
  "Inverse of [[days-from-civil]]: returns `[y m d]`."
  [^long z]
  (let [z (+ z 719468)
        era (Math/floorDiv z 146097)
        doe (- z (* era 146097))
        yoe (quot (- (+ (- doe (quot doe 1460)) (quot doe 36524)) (quot doe 146096)) 365)
        y (+ yoe (* era 400))
        doy (- doe (- (+ (* 365 yoe) (quot yoe 4)) (quot yoe 100)))
        mp (quot (+ (* 5 doy) 2) 153)
        d (inc (- doy (quot (+ (* 153 mp) 2) 5)))
        m (if (< mp 10) (+ mp 3) (- mp 9))]
    [(if (<= m 2) (inc y) y) m d]))

(defn leap-year? [^long y]
  (and (zero? (rem y 4)) (or (pos? (rem y 100)) (zero? (rem y 400)))))

(defn- days-in-month ^long [^long y ^long m]
  (case (int m)
    (1 3 5 7 8 10 12) 31
    (4 6 9 11) 30
    2 (if (leap-year? y) 29 28)))

(defn- strip-comments
  [^String s]
  (let [n (.length s) sb (StringBuilder.)]
    (loop [i 0]
      (when (< i n)
        (if (= (.charAt s i) \()
          (recur (text/skip-comment s i))
          (do (.append sb (.charAt s i)) (recur (inc i))))))
    (.toString sb)))

(defn- digits? [^String s lo hi]
  (and (>= (.length s) lo) (<= (.length s) hi)
       (every? #(and (>= (int %) 48) (<= (int %) 57)) s)))

(defn- parse-int ^long [^String s] (Long/parseLong s))

(defn- format-offset
  [^long minutes]
  (let [a (Math/abs minutes)]
    (format "%s%02d%02d" (if (neg? minutes) "-" "+") (quot a 60) (rem a 60))))

(defn- parse-zone
  ^long [^String z]
  (cond
    (nil? z) 0
    (and (= (.length z) 5) (#{\+ \-} (.charAt z 0)) (digits? (.substring z 1) 4 4))
    (let [m (+ (* 60 (parse-int (.substring z 1 3))) (parse-int (.substring z 3 5)))]
      (if (= (.charAt z 0) \-) (- m) m))
    :else (long (get zones (text/lower z) 0))))

(defn parse
  "Parses the raw `Date` header value. Returns nil when it is not a valid
  date, otherwise `{:epoch n :utc \"YYYY-MM-DDTHH:MM:SSZ\" :offset \"+HHMM\"}`."
  [^String raw]
  (let [toks (remove str/blank? (str/split (strip-comments raw) #"[ \t,]+"))
        toks (if (and (seq toks) (days-of-week (text/lower (first toks)))) (rest toks) toks)
        [day mon year time zone] toks]
    (when (>= (count toks) 4)
      (let [month (get months (text/lower mon))
            tparts (str/split time #":" -1)]
        (when (and (digits? day 1 2) month (digits? year 2 4)
                   (<= 2 (count tparts) 3) (every? #(digits? % 1 2) tparts))
          (let [d (parse-int day)
                yl (.length ^String year)
                y (let [v (parse-int year)]
                    (case yl 2 (if (>= v 50) (+ 1900 v) (+ 2000 v)) 3 (+ 1900 v) v))
                hh (parse-int (first tparts))
                mm (parse-int (second tparts))
                ss (if (= 3 (count tparts)) (parse-int (nth tparts 2)) 0)]
            (when (and (<= 1 d 31) (<= 1 y 9999) (<= hh 23) (<= mm 59) (<= ss 60)
                       (<= d (days-in-month y month)))
              (let [off (parse-zone zone)
                    epoch (+ (* 86400 (days-from-civil y month d)) (* 3600 hh) (* 60 mm) ss (- (* 60 off)))
                    days (Math/floorDiv epoch 86400)
                    sod (- epoch (* 86400 days))
                    [uy um ud] (civil-from-days days)]
                {:epoch epoch
                 :utc (format "%04d-%02d-%02dT%02d:%02d:%02dZ" uy um ud
                              (quot sod 3600) (quot (rem sod 3600) 60) (rem sod 60))
                 :offset (format-offset off)}))))))))
