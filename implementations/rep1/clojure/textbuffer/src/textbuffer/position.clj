(ns textbuffer.position
  "Document positions packed into a single `long`.

  A position `(line, col)` is stored as `line * 2^32 + col`. Because the column
  occupies the low 32 bits, comparing two packed positions with the ordinary
  numeric operators (`<`, `max`, `compare`, ...) is exactly the lexicographic
  order on `(line, col)` that the text buffer uses everywhere.

  Lines and columns are limited to 2^31 - 1, far beyond the document sizes
  the buffer is designed for."
  (:refer-clojure :exclude [min max]))

(set! *warn-on-reflection* true)

(def ^:const origin
  "The position `(0, 0)`: the start of every document."
  0)

(defn pos
  "Packs `line` and `col` (both non-negative) into a position."
  ^long [^long line ^long col]
  (bit-or (bit-shift-left line 32) col))

(defn line
  "The line component of position `p`."
  ^long [^long p]
  (bit-shift-right p 32))

(defn col
  "The column component of position `p`."
  ^long [^long p]
  (bit-and p 0xFFFFFFFF))

(defn min
  "The smaller of two positions."
  ^long [^long a ^long b]
  (if (< a b) a b))

(defn max
  "The larger of two positions."
  ^long [^long a ^long b]
  (if (> a b) a b))

(defn newline-count
  "Number of `\\n` characters in `text`."
  ^long [^String text]
  (let [n (.length text)]
    (loop [i 0 cnt 0]
      (if (< i n)
        (recur (inc i) (if (= (.charAt text i) \newline) (inc cnt) cnt))
        cnt))))

(defn advance
  "The position reached after inserting `text` at position `p`: the end of
  the inserted text. A `\\n` in `text` starts a new line at column 0."
  ^long [^long p ^String text]
  (let [nl (.lastIndexOf text 10)]
    (if (neg? nl)
      (pos (line p) (+ (col p) (.length text)))
      (pos (+ (line p) (newline-count text))
           (- (.length text) nl 1)))))

(defn ->vec
  "Position `p` as a `[line col]` vector, for display and tests."
  [^long p]
  [(line p) (col p)])
