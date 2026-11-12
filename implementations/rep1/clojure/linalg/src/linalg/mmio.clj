(ns linalg.mmio
  "Reading and writing Matrix Market files.

  Reading accepts the `coordinate` and `array` formats with the `real`,
  `integer` and `pattern` fields and the `general`, `symmetric` and
  `skew-symmetric` symmetries, and always produces a dense matrix. Writing
  always produces `array real general` with every value formatted like C's
  `printf(\"%.10e\")`."
  (:require [clojure.string :as str]
            [linalg.matrix :as m])
  (:import (java.math BigDecimal MathContext RoundingMode)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------- reading

(defn- tokens [^String line] (str/split (str/trim line) #"\s+"))

(defn- parse-double* ^double [^String s] (Double/parseDouble s))

(defn- blank? [^String line] (str/blank? line))

(defn- fill-coordinate!
  [^doubles d rows cols symmetry pattern? data-lines]
  (let [cols (long cols)]
    (doseq [^String line data-lines]
      (let [^"[Ljava.lang.String;" t (into-array String (tokens line))
            i (dec (Long/parseLong (aget t 0)))
            j (dec (Long/parseLong (aget t 1)))
            x (if pattern? 1.0 (parse-double* (aget t 2)))]
        (aset d (+ (* i cols) j) x)
        (when (and (not= i j) (not= symmetry "general"))
          (aset d (+ (* j cols) i) (if (= symmetry "skew-symmetric") (- x) x)))))
    d))

(defn- fill-array!
  [^doubles d rows cols symmetry data-lines]
  (let [rows (long rows) cols (long cols)
        vals (map parse-double* data-lines)]
    (if (= symmetry "general")
      (loop [j 0 i 0 vs vals]
        (when (and (< j cols) (seq vs))
          (aset d (+ (* i cols) j) (double (first vs)))
          (if (== (inc i) rows) (recur (inc j) 0 (rest vs)) (recur j (inc i) (rest vs)))))
      (let [skew? (= symmetry "skew-symmetric")
            n rows]
        (loop [j 0 i (if skew? 1 0) vs vals]
          (when (and (< j n) (seq vs))
            (if (< i n)
              (let [x (double (first vs))]
                (aset d (+ (* i cols) j) x)
                (aset d (+ (* j cols) i) (if (and skew? (not= i j)) (- x) x))
                (recur j (inc i) (rest vs)))
              (recur (inc j) (if skew? (+ j 2) (inc j)) vs))))))
    d))

(defn parse
  "Parses the text of a Matrix Market file into a dense matrix."
  [^String text]
  (let [[banner & more] (str/split-lines text)
        [_ _ fmt field symmetry] (map str/lower-case (tokens banner))
        more (remove blank? more)
        more (drop-while #(str/starts-with? % "%") more)
        [size-line & data-lines] more
        size (map #(Long/parseLong %) (tokens size-line))
        rows (first size) cols (second size)
        d (double-array (* rows cols))]
    (if (= fmt "coordinate")
      (fill-coordinate! d rows cols symmetry (= field "pattern") data-lines)
      (fill-array! d rows cols symmetry data-lines))
    (m/matrix rows cols d)))

(defn read-matrix
  "Reads the Matrix Market file at `path` (a string or `java.io.File`) into a
  dense matrix."
  [path]
  (parse (slurp path :encoding "UTF-8")))

;; ---------------------------------------------------------------- writing

(def ^:private ^MathContext eleven-digits (MathContext. 11 RoundingMode/HALF_EVEN))

(defn format-double
  "Formats a finite double exactly like C's `printf(\"%.10e\")`, except that
  negative zero is written as zero."
  ^String [^double x]
  (if (== x 0.0)
    "0.0000000000e+00"
    (let [bd (.round (BigDecimal. (Math/abs x)) eleven-digits)
          digits (str (.unscaledValue bd))
          exponent (- (dec (count digits)) (.scale bd))
          digits (if (< (count digits) 11)
                   (str digits (apply str (repeat (- 11 (count digits)) \0)))
                   digits)
          e (Math/abs exponent)]
      (str (when (< x 0.0) "-")
           (.charAt digits 0) "." (subs digits 1)
           "e" (if (neg? exponent) "-" "+")
           (when (< e 10) "0") e))))

(defn format-matrix
  "The `array real general` Matrix Market text of `a`: banner, size line, then
  one value per line in column-major order, ending with a newline."
  ^String [^linalg.matrix.Matrix a]
  (let [rows (.rows a) cols (.cols a)
        ^doubles d (.data a)
        sb (StringBuilder. (+ 64 (* 18 rows cols)))]
    (.append sb "%%MatrixMarket matrix array real general\n")
    (.append sb rows) (.append sb \space) (.append sb cols) (.append sb \newline)
    (dotimes [j cols]
      (dotimes [i rows]
        (.append sb (format-double (aget d (+ (* i cols) j))))
        (.append sb \newline)))
    (.toString sb)))

(defn write-matrix
  "Writes `a` to the file at `path` in `array real general` form."
  [path a]
  (spit path (format-matrix a) :encoding "UTF-8"))
