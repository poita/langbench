(ns qrcode.segment
  "Mode selection, version selection and data-segment encoding."
  (:require [qrcode.bits :as bits]
            [qrcode.tables :as tables]))

(set! *warn-on-reflection* true)

(def ^:private alphanumeric-charset
  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")

(def ^:private ^"[I" alphanumeric-values
  (let [a (int-array 256 -1)]
    (dotimes [i (count alphanumeric-charset)]
      (aset a (int (.charAt ^String alphanumeric-charset i)) i))
    a))

(defn select-mode
  "Returns :numeric, :alphanumeric or :byte for the byte array `data`,
  choosing the first applicable mode."
  [^bytes data]
  (let [n (alength data)]
    (loop [i 0, numeric? true, alnum? true]
      (cond
        (not (or numeric? alnum?)) :byte
        (== i n) (if numeric? :numeric :alphanumeric)
        :else
        (let [b (bit-and (aget data i) 0xFF)]
          (recur (inc i)
                 (and numeric? (<= 48 b 57))
                 (and alnum? (>= (aget alphanumeric-values b) 0))))))))

(def ^:private mode-indicator {:numeric 1, :alphanumeric 2, :byte 4})

(def ^:private count-bits
  {:numeric [10 12 14], :alphanumeric [9 11 13], :byte [8 16 16]})

(defn count-indicator-bits
  "Width in bits of the character count indicator for `mode` at version `v`."
  ^long [mode ^long v]
  (long (get-in count-bits [mode (cond (<= v 9) 0 (<= v 26) 1 :else 2)])))

(defn data-bit-length
  "Number of data bits for `n` characters in `mode`."
  ^long [mode ^long n]
  (case mode
    :numeric (+ (* 10 (quot n 3)) (case (long (rem n 3)) 0 0, 1 4, 2 7))
    :alphanumeric (+ (* 11 (quot n 2)) (* 6 (rem n 2)))
    :byte (* 8 n)))

(defn stream-bit-length
  "Bits needed for the segment (mode indicator, count and data) at version `v`."
  ^long [mode ^long n ^long v]
  (+ 4 (count-indicator-bits mode v) (data-bit-length mode n)))

(defn choose-version
  "Smallest version 1..40 whose data capacity at `ecl` holds `n` characters of
  `mode`, or nil when none does."
  [mode ^long n ecl]
  (loop [v 1]
    (cond
      (> v 40) nil
      (<= (stream-bit-length mode n v) (* 8 (tables/data-codewords ecl v))) v
      :else (recur (inc v)))))

(defn write-segment!
  "Appends the segment for `data` (mode indicator, count, data bits) to the
  bit buffer `buf`, for symbol version `v`. Returns `buf`."
  [buf mode ^bytes data ^long v]
  (let [n (alength data)]
    (bits/append! buf (mode-indicator mode) 4)
    (bits/append! buf n (count-indicator-bits mode v))
    (case mode
      :numeric
      (loop [i 0]
        (let [left (- n i)]
          (when (pos? left)
            (let [k (min 3 left)
                  value (loop [j 0, acc 0]
                          (if (< j k)
                            (recur (inc j) (+ (* acc 10) (- (aget data (+ i j)) 48)))
                            acc))]
              (bits/append! buf value (case (long k) 1 4, 2 7, 3 10))
              (recur (+ i k))))))

      :alphanumeric
      (loop [i 0]
        (let [left (- n i)
              val (fn [j] (aget alphanumeric-values (bit-and (aget data j) 0xFF)))]
          (cond
            (>= left 2) (do (bits/append! buf (+ (* 45 (val i)) (val (inc i))) 11)
                            (recur (+ i 2)))
            (== left 1) (bits/append! buf (val i) 6))))

      :byte
      (dotimes [i n]
        (bits/append! buf (bit-and (aget data i) 0xFF) 8)))
    buf))
