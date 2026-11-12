(ns spreadsheet.format
  "Display of values. Numbers follow C's `printf(\"%.10g\")` with correct
  (round-half-even) rounding, except that integral values below 1e15 print as
  plain integers."
  (:import (java.math BigDecimal MathContext RoundingMode)))

(def error-codes
  {:error/div0 "#DIV/0!"
   :error/ref "#REF!"
   :error/cycle "#CYCLE!"
   :error/value "#VALUE!"})

(defn- format-g10
  "printf-style %.10g of the finite, non-zero double `v`."
  [^double v]
  (let [bd (.round (BigDecimal. v) (MathContext. 10 RoundingMode/HALF_EVEN))
        negative? (neg? (.signum bd))
        bd (.stripTrailingZeros (.abs bd))
        digits (str (.unscaledValue bd))
        e (- (count digits) 1 (.scale bd))
        body (if (or (< e -4) (>= e 10))
               (str (first digits)
                    (when (> (count digits) 1) (str "." (subs digits 1)))
                    "e" (if (neg? e) "-" "+")
                    (let [m (Math/abs e)] (if (< m 10) (str "0" m) m)))
               (cond
                 (neg? e) (str "0." (apply str (repeat (- (- e) 1) "0")) digits)
                 (>= e (dec (count digits)))
                 (str digits (apply str (repeat (- e (dec (count digits))) "0")))
                 :else (str (subs digits 0 (inc e)) "." (subs digits (inc e)))))]
    (if negative? (str "-" body) body)))

(defn number->string
  "The display (and text) form of the finite double `v`."
  [^double v]
  (cond
    (zero? v) "0"
    (and (== v (Math/floor v)) (< (Math/abs v) 1e15)) (str (long v))
    :else (format-g10 v)))

(defn display
  "Display string of a cell value: nil (empty) -> \"\", a double, a string, or
  an error keyword such as `:error/div0`."
  [v]
  (cond
    (nil? v) ""
    (string? v) v
    (keyword? v) (error-codes v)
    :else (number->string v)))
