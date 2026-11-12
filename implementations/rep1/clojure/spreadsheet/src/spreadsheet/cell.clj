(ns spreadsheet.cell
  "Cell addressing.

  A cell is identified internally by a long *id* that encodes its row and
  column so that ascending ids are in row-major order. Cell names are one or
  two uppercase letters (columns 1..702) followed by a row number 1..9999
  without leading zeros, e.g. `A1`, `ZZ9999`.")

(def ^:const max-col 702)
(def ^:const max-row 9999)

(defn ->id
  "Encodes 1-based `col` and `row` as a cell id. Ids sort in row-major order."
  ^long [^long col ^long row]
  (+ (* row 1024) col))

(defn id->row ^long [^long id] (quot id 1024))
(defn id->col ^long [^long id] (rem id 1024))

(defn- upper? [c] (and (>= (int c) (int \A)) (<= (int c) (int \Z))))
(defn- digit? [c] (and (>= (int c) (int \0)) (<= (int c) (int \9))))

(defn parse-ref
  "Parses the cell name `s` and returns its id, or nil if `s` is not a valid
  cell name (too many letters, row 0, leading zero, row above 9999, ...)."
  [^String s]
  (let [n (.length s)
        letters (loop [i 0] (if (and (< i n) (upper? (.charAt s i))) (recur (inc i)) i))
        digits (- n letters)]
    (when (and (<= 1 letters 2) (<= 1 digits 4)
               (not= \0 (.charAt s letters))
               (every? digit? (subs s letters)))
      (let [col (reduce (fn [acc i] (+ (* acc 26) (- (int (.charAt s i)) 64)))
                        0 (range letters))
            row (Long/parseLong (subs s letters))]
        (when (<= 1 row max-row)
          (->id col row))))))

(defn col-name
  "Returns the column letters for 1-based column `col`."
  [^long col]
  (if (> col 26)
    (str (char (+ 64 (quot (dec col) 26))) (char (+ 65 (rem (dec col) 26))))
    (str (char (+ 64 col)))))

(defn id->name
  "Returns the cell name (e.g. \"B12\") for `id`."
  [^long id]
  (str (col-name (id->col id)) (id->row id)))
