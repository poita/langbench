(ns minisql.value
  "The SQL value model: NULL, INTEGER, TEXT and REAL.

  * NULL is `nil`;
  * INTEGER is a `Long`;
  * TEXT is a `String`;
  * REAL is a [[Real]], a number of hundredths.  Only `AVG` produces one.

  Also here: the total order used for comparison, sorting, grouping, MIN and
  MAX; three-valued truth; and rendering of values for output.")

(set! *warn-on-reflection* true)

(defrecord Real [^long hundredths])

(defn real?
  "True if `v` is a REAL value."
  [v]
  (instance? Real v))

(defn- rank
  "Kind rank in the total order: NULL < numbers < text."
  ^long [v]
  (cond (nil? v) 0
        (string? v) 2
        :else 1))

(defn- fold-surrogate
  "Map a UTF-16 unit so that numeric order equals code point order."
  ^long [^long c]
  (cond (>= c 0xE000) (- c 0x800)
        (>= c 0xD800) (+ c 0x2000)
        :else c))

(defn compare-text
  "Compare two strings by Unicode code point."
  ^long [^String a ^String b]
  (let [la (.length a) lb (.length b) n (Math/min la lb)]
    (loop [i 0]
      (if (< i n)
        (let [ca (long (int (.charAt a i))) cb (long (int (.charAt b i)))]
          (if (== ca cb)
            (recur (inc i))
            (Long/compare (fold-surrogate ca) (fold-surrogate cb))))
        (Long/compare la lb)))))

(defn- compare-numbers ^long [a b]
  (let [ra (real? a) rb (real? b)]
    (cond
      (and (not ra) (not rb)) (Long/compare (long a) (long b))
      (and ra rb) (Long/compare (.hundredths ^Real a) (.hundredths ^Real b))
      ra (long (compare (.hundredths ^Real a) (*' 100 (long b))))
      :else (long (compare (*' 100 (long a)) (.hundredths ^Real b))))))

(defn compare-values
  "Three-way comparison implementing the total order of SPEC.md: NULL first,
  then numbers (INTEGER and REAL by value), then TEXT by code point.
  Returns a negative, zero or positive long."
  ^long [a b]
  (if (and (instance? Long a) (instance? Long b))
    (Long/compare (long a) (long b))
    (let [ra (rank a) rb (rank b)]
      (cond
        (not= ra rb) (Long/compare ra rb)
        (== ra 0) 0
        (== ra 2) (compare-text a b)
        :else (compare-numbers a b)))))

(defn compare-rows
  "Lexicographic [[compare-values]] over two equal-length vectors."
  ^long [a b]
  (let [n (count a)]
    (loop [i 0]
      (if (< i n)
        (let [c (compare-values (nth a i) (nth b i))]
          (if (zero? c) (recur (inc i)) c))
        0))))

(defn truth
  "Interpret `v` as a three-valued boolean: `true`, `false`, or `nil` for
  unknown (NULL)."
  [v]
  (cond (nil? v) nil
        (instance? Long v) (not (zero? (long v)))
        (real? v) (not (zero? (.hundredths ^Real v)))
        :else false))

(defn bool->value
  "Convert `true`/`false`/`nil` to INTEGER 1 / INTEGER 0 / NULL."
  [b]
  (case b true 1 false 0 nil))

(defn average
  "The REAL average of `sum` over `cnt` (> 0) integers, rounded to two
  decimals, half away from zero."
  [^long sum ^long cnt]
  (let [h (quot (+ (* 200 (Math/abs sum)) cnt) (* 2 cnt))]
    (->Real (if (neg? sum) (- h) h))))

(defn render
  "The output text of a value: `NULL`, a decimal integer, the raw text, or a
  REAL with exactly two decimals."
  ^String [v]
  (cond
    (nil? v) "NULL"
    (string? v) v
    (real? v) (let [h (.hundredths ^Real v)
                    a (Math/abs h)]
                (str (when (neg? h) "-") (quot a 100) "."
                     (let [r (rem a 100)] (str (when (< r 10) "0") r))))
    :else (str v)))
