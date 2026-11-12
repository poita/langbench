(ns toml.convert
  "Conversion between tagged trees (`toml.data`) and ordinary Clojure data.

  | TOML              | Clojure                                          |
  |-------------------|--------------------------------------------------|
  | string            | `String`                                         |
  | integer           | `Long`                                           |
  | float             | `Double`                                         |
  | bool              | `Boolean`                                        |
  | datetime          | `java.time.OffsetDateTime`                       |
  | datetime-local    | `java.time.LocalDateTime`                        |
  | date-local        | `java.time.LocalDate`                            |
  | time-local        | `java.time.LocalTime`                            |
  | array             | vector                                           |
  | table             | map with string (or, optionally, keyword) keys   |

  Fractional seconds beyond nanosecond precision are truncated on the way to
  `java.time`."
  (:require [toml.data :as d]
            [toml.number :as num])
  (:import (java.time Instant LocalDate LocalDateTime LocalTime OffsetDateTime ZoneOffset ZonedDateTime)))

(set! *warn-on-reflection* true)

;; ------------------------------------------------------- tagged -> natural

(defn- truncate-fraction
  "Truncates fractional seconds in canonical time text to nine digits."
  ^String [^String text]
  (if-let [dot (let [i (.indexOf text 46)] (when (>= i 0) i))]
    (let [end (loop [k (inc dot)]
                (if (and (< k (.length text)) (<= 48 (int (.charAt text k)) 57)) (recur (inc k)) k))]
      (str (subs text 0 (min end (+ dot 10))) (subs text end)))
    text))

(defn- scalar->natural [{:keys [type value]}]
  (case type
    :string value
    :integer (Long/parseLong value)
    :float (num/parse-float-text value)
    :bool (= value "true")
    :datetime (OffsetDateTime/parse (truncate-fraction value))
    :datetime-local (LocalDateTime/parse (truncate-fraction value))
    :date-local (LocalDate/parse value)
    :time-local (LocalTime/parse (truncate-fraction value))))

(defn tagged->natural
  "Converts a tagged tree to ordinary Clojure data.  Option `:key-fn` is
  applied to every table key (e.g. `keyword`)."
  ([tree] (tagged->natural tree nil))
  ([tree {:keys [key-fn] :or {key-fn identity}}]
   (letfn [(conv [node]
             (cond (d/scalar? node) (scalar->natural node)
                   (map? node) (persistent!
                                (reduce-kv (fn [m k v] (assoc! m (key-fn k) (conv v)))
                                           (transient {}) node))
                   :else (mapv conv node)))]
     (conv tree))))

;; ------------------------------------------------------- natural -> tagged

(defn- pad [^long n ^long width]
  (let [s (str n)] (str (apply str (repeat (- width (count s)) \0)) s)))

(defn- time-text [^LocalTime t]
  (let [base (str (pad (.getHour t) 2) ":" (pad (.getMinute t) 2) ":" (pad (.getSecond t) 2))
        nanos (.getNano t)]
    (if (zero? nanos)
      base
      (str base "." (.replaceAll ^String (pad nanos 9) "0+$" "")))))

(defn- date-text [^LocalDate dt]
  (let [y (.getYear dt)]
    (when-not (<= 1 y 9999) (throw (ex-info "Year out of the range TOML can express" {:year y})))
    (str (pad y 4) "-" (pad (.getMonthValue dt) 2) "-" (pad (.getDayOfMonth dt) 2))))

(defn- offset-text [^ZoneOffset off]
  (let [total (quot (.getTotalSeconds off) 60)]
    (if (zero? total)
      "Z"
      (str (if (neg? total) "-" "+") (pad (quot (Math/abs total) 60) 2) ":" (pad (rem (Math/abs total) 60) 2)))))

(defn- key-text [k]
  (cond (string? k) k
        (keyword? k) (if-let [ns (namespace k)] (str ns "/" (name k)) (name k))
        (symbol? k) (str k)
        :else (throw (ex-info "TOML keys must be strings or keywords" {:key k}))))

(defn natural->tagged
  "Converts ordinary Clojure data to a tagged tree.  Maps become tables
  (keywords are converted to strings), sequential collections become arrays.
  Integers must fit in 64 bits; `nil` has no TOML representation.  Tagged
  scalars pass through unchanged."
  [data]
  (letfn [(conv [x]
            (cond
              (d/scalar? x) x
              (string? x) (d/scalar :string x)
              (instance? Boolean x) (d/scalar :bool (str x))
              (or (instance? Long x) (instance? Integer x) (instance? Short x) (instance? Byte x))
              (d/scalar :integer (str (long x)))
              (or (instance? clojure.lang.BigInt x) (instance? java.math.BigInteger x))
              (d/scalar :integer (str (.longValueExact (biginteger x))))
              (or (instance? Double x) (instance? Float x))
              (d/scalar :float (num/format-float (double x)))
              (instance? OffsetDateTime x)
              (d/scalar :datetime (str (date-text (.toLocalDate ^OffsetDateTime x)) "T"
                                       (time-text (.toLocalTime ^OffsetDateTime x))
                                       (offset-text (.getOffset ^OffsetDateTime x))))
              (instance? ZonedDateTime x) (conv (.toOffsetDateTime ^ZonedDateTime x))
              (instance? Instant x) (conv (OffsetDateTime/ofInstant x ZoneOffset/UTC))
              (instance? LocalDateTime x)
              (d/scalar :datetime-local (str (date-text (.toLocalDate ^LocalDateTime x)) "T"
                                             (time-text (.toLocalTime ^LocalDateTime x))))
              (instance? LocalDate x) (d/scalar :date-local (date-text x))
              (instance? LocalTime x) (d/scalar :time-local (time-text x))
              (map? x) (persistent! (reduce-kv (fn [m k v] (assoc! m (key-text k) (conv v)))
                                               (transient {}) x))
              (sequential? x) (mapv conv x)
              :else (throw (ex-info (str "Cannot represent value as TOML: " (pr-str x)) {:value x}))))]
    (conv data)))
