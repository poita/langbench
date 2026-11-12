(ns qrcode.tables
  "Constant tables and closed-form capacity formulas for QR Code Model 2
  (ISO/IEC 18004), versions 1..40."
  (:require [clojure.string :as str]))

(set! *warn-on-reflection* true)

(def ecls
  "Error correction levels, lowest to highest."
  [:l :m :q :h])

(def ^:private ecl-index {:l 0, :m 1, :q 2, :h 3})

(def ecl-format-bits
  "The two-bit error correction level indicator used in format information."
  {:l 1, :m 0, :q 3, :h 2})

(defn- row
  "Parses a whitespace separated string of 40 integers into a vector."
  [s]
  (mapv parse-long (str/split s #"\s+")))

(def ^:private ecc-per-block
  [(row "7 10 15 20 26 18 20 24 30 18 20 24 26 30 22 24 28 30 28 28 28 28 30 30 26 28 30 30 30 30 30 30 30 30 30 30 30 30 30 30")
   (row "10 16 26 18 24 16 18 22 22 26 30 22 22 24 24 28 28 26 26 26 26 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28")
   (row "13 22 18 26 18 24 18 22 20 24 28 26 24 20 30 24 28 28 26 30 28 30 30 30 30 28 30 30 30 30 30 30 30 30 30 30 30 30 30 30")
   (row "17 28 22 16 22 28 26 26 24 28 24 28 22 24 24 30 28 28 26 28 30 24 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30")])

(def ^:private block-counts
  [(row "1 1 1 1 1 2 2 2 2 4 4 4 4 4 6 6 6 6 7 8 8 9 9 10 12 12 12 13 14 15 16 17 18 19 19 20 21 22 24 25")
   (row "1 1 1 2 2 4 4 4 5 5 5 8 9 9 10 10 11 13 14 16 17 17 18 20 21 23 25 26 28 29 31 33 35 37 38 40 43 45 47 49")
   (row "1 1 2 2 4 4 6 6 8 8 8 10 12 16 12 17 16 18 21 20 23 23 25 27 29 34 34 35 38 40 43 45 48 51 53 56 59 62 65 68")
   (row "1 1 2 4 4 4 5 6 8 8 11 11 16 16 18 16 19 21 25 25 25 34 30 32 35 37 40 42 45 48 51 54 57 60 63 66 70 74 77 81")])

(def ^:private alignment-table
  "Alignment pattern centre coordinates for versions 2..40 (index = v - 2)."
  [[6 18] [6 22] [6 26] [6 30] [6 34]
   [6 22 38] [6 24 42] [6 26 46] [6 28 50] [6 30 54] [6 32 58] [6 34 62]
   [6 26 46 66] [6 26 48 70] [6 26 50 74] [6 30 54 78] [6 30 56 82]
   [6 30 58 86] [6 34 62 90]
   [6 28 50 72 94] [6 26 50 74 98] [6 30 54 78 102] [6 28 54 80 106]
   [6 32 58 84 110] [6 30 58 86 114] [6 34 62 90 118]
   [6 26 50 74 98 122] [6 30 54 78 102 126] [6 26 52 78 104 130]
   [6 30 56 82 108 134] [6 34 60 86 112 138] [6 30 58 86 114 142]
   [6 34 62 90 118 146]
   [6 30 54 78 102 126 150] [6 24 50 76 102 128 154]
   [6 28 54 80 106 132 158] [6 32 58 84 110 136 162]
   [6 26 54 82 110 138 166] [6 30 58 86 114 142 170]])

(defn check-version
  "Returns `v` if it is a valid version number (1..40), else throws."
  [v]
  (if (and (integer? v) (<= 1 v 40))
    v
    (throw (ex-info "Version must be an integer in 1..40" {:version v}))))

(defn check-ecl
  "Returns `ecl` if it is one of :l :m :q :h, else throws."
  [ecl]
  (if (contains? ecl-index ecl)
    ecl
    (throw (ex-info "Error correction level must be one of :l :m :q :h" {:ecl ecl}))))

(defn symbol-size
  "Side length in modules of a symbol of version `v`."
  ^long [^long v]
  (+ 17 (* 4 v)))

(defn raw-modules
  "Number of modules available for codewords (data + ECC + remainder bits)
  in version `v`."
  ^long [^long v]
  (let [raw (+ (* (+ (* 16 v) 128) v) 64)
        raw (if (>= v 2)
              (let [a (+ (quot v 7) 2)]
                (- raw (- (* (- (* 25 a) 10) a) 55)))
              raw)]
    (if (>= v 7) (- raw 36) raw)))

(defn total-codewords
  "Total number of codewords (data + ECC) in version `v`."
  ^long [^long v]
  (quot (raw-modules v) 8))

(defn ecc-codewords-per-block
  "Number of error correction codewords in each block."
  ^long [ecl ^long v]
  (long (get-in ecc-per-block [(ecl-index ecl) (dec v)])))

(defn block-count
  "Number of Reed-Solomon blocks."
  ^long [ecl ^long v]
  (long (get-in block-counts [(ecl-index ecl) (dec v)])))

(defn data-codewords
  "Number of data codewords in version `v` at level `ecl`."
  ^long [ecl ^long v]
  (- (total-codewords v)
     (* (ecc-codewords-per-block ecl v) (block-count ecl v))))

(defn alignment-positions
  "Coordinates used to place alignment patterns in version `v` (empty for 1)."
  [^long v]
  (if (= v 1) [] (alignment-table (- v 2))))
