(ns toml.parser
  "Recursive-descent reader for TOML 1.0.0 text.

  The reader makes a single pass over the document; every scanner is bounded
  by the token or line it reads, so reading is linear in the input size.
  Scalars are turned into canonical text (`toml.number`, `toml.datetime`)
  and tables are resolved by `toml.table` as they are read."
  (:require [toml.data :as d]
            [toml.datetime :as dt]
            [toml.error :refer [fail]]
            [toml.number :as num]
            [toml.table :as tbl])
  (:import (java.lang StringBuilder)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------- cursor

(definterface ICursor
  (^long pos [])
  (seek [^long p]))

(deftype Cursor [^String s ^:unsynchronized-mutable ^long p]
  ICursor
  (pos [_] p)
  (seek [_ q] (set! p q) nil))

(defn- cur
  "Code unit at the cursor, or -1 at the end of input."
  ^long [^Cursor c]
  (let [^String s (.-s c) i (.pos c)]
    (if (< i (.length s)) (long (int (.charAt s i))) -1)))

(defn- at
  "Code unit `off` positions after the cursor, or -1."
  ^long [^Cursor c ^long off]
  (let [^String s (.-s c) i (+ (.pos c) off)]
    (if (< i (.length s)) (long (int (.charAt s i))) -1)))

(defn- bump! [^Cursor c ^long n] (.seek c (+ (.pos c) n)))

(defn- err [^Cursor c msg] (fail msg (.pos c)))

;; ------------------------------------------------ whitespace, comments

(defn- ws? [^long ch] (or (== ch 32) (== ch 9)))

(defn- skip-ws! [^Cursor c]
  (loop [] (when (ws? (cur c)) (bump! c 1) (recur))))

(defn- newline-len
  "Length of the newline at the cursor: 1 for LF, 2 for CRLF, else 0."
  ^long [^Cursor c]
  (let [ch (cur c)]
    (cond (== ch 10) 1
          (and (== ch 13) (== (at c 1) 10)) 2
          :else 0)))

(defn- control? [^long ch]
  (or (and (< ch 32) (not (== ch 9))) (== ch 127)))

(defn- skip-comment!
  "Skips a comment (cursor on `#`) up to, but not including, the newline."
  [^Cursor c]
  (bump! c 1)
  (loop []
    (let [ch (cur c)]
      (cond (== ch -1) nil
            (== ch 10) nil
            (== ch 13) (when-not (== (at c 1) 10) (err c "bare carriage return"))
            (control? ch) (err c "control character in comment")
            :else (do (bump! c 1) (recur))))))

(defn- skip-ws-nl-comments!
  "Skips whitespace, newlines and comments (the gaps inside an array)."
  [^Cursor c]
  (loop []
    (let [ch (cur c)]
      (cond (ws? ch) (do (bump! c 1) (recur))
            (== ch 35) (do (skip-comment! c) (recur))
            :else (let [n (newline-len c)]
                    (when (pos? n) (bump! c n) (recur)))))))

(defn- end-of-line!
  "After a statement: optional whitespace and comment, then a newline or EOF."
  [^Cursor c]
  (skip-ws! c)
  (when (== (cur c) 35) (skip-comment! c))
  (let [n (newline-len c)]
    (cond (pos? n) (bump! c n)
          (== (cur c) -1) nil
          :else (err c "expected a newline after the statement"))))

;; ---------------------------------------------------------------- strings

(defn- hex-val ^long [^long ch]
  (cond (and (>= ch 48) (<= ch 57)) (- ch 48)
        (and (>= ch 97) (<= ch 102)) (- ch 87)
        (and (>= ch 65) (<= ch 70)) (- ch 55)
        :else -1))

(defn- read-unicode-escape! [^Cursor c ^StringBuilder sb ^long n]
  (loop [k 0 cp 0]
    (if (< k n)
      (let [h (hex-val (at c k))]
        (when (neg? h) (err c "invalid unicode escape"))
        (recur (unchecked-inc k) (+ (* cp 16) h)))
      (do (when (or (> cp 0x10FFFF) (and (>= cp 0xD800) (<= cp 0xDFFF)))
            (err c "escape is not a unicode scalar value"))
          (.appendCodePoint sb (int cp))
          (bump! c n)))))

(defn- read-escape!
  "Reads the escape whose backslash has just been consumed."
  [^Cursor c ^StringBuilder sb]
  (let [ch (cur c)]
    (case ch
      98  (do (.append sb (char 8)) (bump! c 1))
      116 (do (.append sb (char 9)) (bump! c 1))
      110 (do (.append sb (char 10)) (bump! c 1))
      102 (do (.append sb (char 12)) (bump! c 1))
      114 (do (.append sb (char 13)) (bump! c 1))
      34  (do (.append sb (char 34)) (bump! c 1))
      92  (do (.append sb (char 92)) (bump! c 1))
      117 (do (bump! c 1) (read-unicode-escape! c sb 4))
      85  (do (bump! c 1) (read-unicode-escape! c sb 8))
      (err c "invalid escape sequence"))))

(defn- read-basic-string!
  "Reads `\"...\"` (cursor on the opening quote); returns the string."
  ^String [^Cursor c]
  (bump! c 1)
  (let [sb (StringBuilder.)]
    (loop []
      (let [ch (cur c)]
        (cond (== ch 34) (do (bump! c 1) (.toString sb))
              (== ch 92) (do (bump! c 1) (read-escape! c sb) (recur))
              (or (== ch -1) (control? ch)) (err c "unterminated or invalid string")
              :else (do (.append sb (char ch)) (bump! c 1) (recur)))))))

(defn- read-literal-string!
  "Reads `'...'` (cursor on the opening quote); returns the string."
  ^String [^Cursor c]
  (bump! c 1)
  (let [sb (StringBuilder.)]
    (loop []
      (let [ch (cur c)]
        (cond (== ch 39) (do (bump! c 1) (.toString sb))
              (or (== ch -1) (control? ch)) (err c "unterminated or invalid literal string")
              :else (do (.append sb (char ch)) (bump! c 1) (recur)))))))

(defn- run-length
  "Number of consecutive `q` characters at the cursor."
  ^long [^Cursor c ^long q]
  (loop [k 0] (if (== (at c k) q) (recur (unchecked-inc k)) k)))

(defn- append-quotes! [^StringBuilder sb ^long q ^long n]
  (dotimes [_ n] (.append sb (char q))))

(defn- line-ending-backslash?
  "True when the cursor (just after a backslash) is at optional whitespace
  followed by a newline."
  [^Cursor c]
  (let [j (loop [k 0] (if (ws? (at c k)) (recur (unchecked-inc k)) k))
        ch (at c j)]
    (or (== ch 10) (and (== ch 13) (== (at c (inc j)) 10)))))

(defn- skip-trimmed-whitespace! [^Cursor c]
  (loop []
    (let [n (newline-len c)]
      (cond (ws? (cur c)) (do (bump! c 1) (recur))
            (pos? n) (do (bump! c n) (recur))))))

(defn- read-multiline!
  "Reads a multi-line string (cursor on the opening delimiter of quote
  character `q`, 34 for basic and 39 for literal)."
  ^String [^Cursor c ^long q]
  (bump! c 3)
  (bump! c (newline-len c))
  (let [sb (StringBuilder.)
        basic? (== q 34)]
    (loop []
      (let [ch (cur c)]
        (cond
          (== ch -1) (err c "unterminated multi-line string")
          (== ch q)  (let [n (run-length c q)]
                       (cond (< n 3) (do (append-quotes! sb q n) (bump! c n) (recur))
                             (> n 5) (err c "too many quotes in multi-line string")
                             :else (do (append-quotes! sb q (- n 3)) (bump! c n) (.toString sb))))
          (and basic? (== ch 92))
          (do (bump! c 1)
              (if (line-ending-backslash? c)
                (do (skip-ws! c) (skip-trimmed-whitespace! c))
                (read-escape! c sb))
              (recur))
          (== ch 13) (if (== (at c 1) 10)
                       (do (.append sb (char 10)) (bump! c 2) (recur))
                       (err c "bare carriage return"))
          (== ch 10) (do (.append sb (char 10)) (bump! c 1) (recur))
          (control? ch) (err c "control character in string")
          :else (do (.append sb (char ch)) (bump! c 1) (recur)))))))

;; ------------------------------------------------------------------- keys

(defn- bare-key-char? [^long ch]
  (or (and (>= ch 97) (<= ch 122)) (and (>= ch 65) (<= ch 90))
      (and (>= ch 48) (<= ch 57)) (== ch 95) (== ch 45)))

(defn- read-simple-key! ^String [^Cursor c]
  (let [ch (cur c)]
    (cond
      (== ch 34) (read-basic-string! c)
      (== ch 39) (read-literal-string! c)
      (bare-key-char? ch)
      (let [start (.pos c)]
        (loop [] (when (bare-key-char? (cur c)) (bump! c 1) (recur)))
        (subs (.-s c) start (.pos c)))
      :else (err c "expected a key"))))

(defn- read-key!
  "Reads a possibly dotted key; returns a vector of its parts.  Whitespace
  after the key is consumed."
  [^Cursor c]
  (loop [acc (transient [])]
    (let [acc (conj! acc (read-simple-key! c))]
      (skip-ws! c)
      (if (== (cur c) 46)
        (do (bump! c 1) (skip-ws! c) (recur acc))
        (persistent! acc)))))

;; ----------------------------------------------------------------- values

(declare read-value!)

(defn- read-array! [^Cursor c]
  (bump! c 1)
  (let [arr (tbl/new-array)]
    (loop []
      (skip-ws-nl-comments! c)
      (let [ch (cur c)]
        (cond
          (== ch 93) (bump! c 1)
          (== ch 44) (err c "unexpected comma in array")
          :else
          (do (tbl/array-add! arr (read-value! c))
              (skip-ws-nl-comments! c)
              (let [ch (cur c)]
                (cond (== ch 44) (do (bump! c 1) (recur))
                      (== ch 93) (bump! c 1)
                      :else (err c "expected `,` or `]` in array")))))))
    arr))

(defn- read-inline-table! [^Cursor c]
  (bump! c 1)
  (let [t (tbl/new-table :inline)]
    (skip-ws! c)
    (if (== (cur c) 125)
      (bump! c 1)
      (loop []
        (let [pos (.pos c)
              path (read-key! c)]
          (when-not (== (cur c) 61) (err c "expected `=`"))
          (bump! c 1)
          (skip-ws! c)
          (tbl/assign! t path (read-value! c) pos)
          (skip-ws! c)
          (let [ch (cur c)]
            (cond (== ch 44) (do (bump! c 1) (skip-ws! c) (recur))
                  (== ch 125) (bump! c 1)
                  :else (err c "expected `,` or `}` in inline table"))))))
    t))

(defn- bare-token-char? [^long ch]
  (or (bare-key-char? ch) (== ch 43) (== ch 46)))

(defn- read-token! ^String [^Cursor c]
  (let [start (.pos c)]
    (loop [] (when (bare-token-char? (cur c)) (bump! c 1) (recur)))
    (subs (.-s c) start (.pos c))))

(defn- digit? [^long ch] (and (>= ch 48) (<= ch 57)))

(defn- datetime-start?
  "True when the text at the cursor starts like `HH:` or `YYYY-`."
  [^Cursor c]
  (and (digit? (cur c)) (digit? (at c 1))
       (or (== (at c 2) 58)
           (and (digit? (at c 2)) (digit? (at c 3)) (== (at c 4) 45)))))

(defn- read-value! [^Cursor c]
  (let [ch (cur c)]
    (cond
      (== ch 34) (d/scalar :string (if (and (== (at c 1) 34) (== (at c 2) 34))
                                     (read-multiline! c 34)
                                     (read-basic-string! c)))
      (== ch 39) (d/scalar :string (if (and (== (at c 1) 39) (== (at c 2) 39))
                                     (read-multiline! c 39)
                                     (read-literal-string! c)))
      (== ch 91) (read-array! c)
      (== ch 123) (read-inline-table! c)
      (datetime-start? c)
      (if-let [[scalar end] (dt/scan (.-s c) (.pos c))]
        (do (.seek c (long end)) scalar)
        (err c "invalid date or time"))
      :else
      (let [pos (.pos c)
            tok (read-token! c)]
        (cond
          (= tok "true") (d/scalar :bool "true")
          (= tok "false") (d/scalar :bool "false")
          (.isEmpty tok) (fail "expected a value" pos)
          :else (or (num/parse-number tok) (fail (str "invalid value `" tok "`") pos)))))))

;; ------------------------------------------------------------- statements

(defn- read-header! [^Cursor c ^toml.table.Tbl root]
  (let [pos (.pos c)
        array? (== (at c 1) 91)]
    (bump! c (if array? 2 1))
    (skip-ws! c)
    (let [path (read-key! c)]
      (when-not (== (cur c) 93) (err c "expected `]`"))
      (bump! c 1)
      (when array?
        (when-not (== (cur c) 93) (err c "expected `]]`"))
        (bump! c 1))
      (end-of-line! c)
      (if array?
        (tbl/open-array-table! root path pos)
        (tbl/open-table! root path pos)))))

(defn- read-pair! [^Cursor c current]
  (let [pos (.pos c)
        path (read-key! c)]
    (when-not (== (cur c) 61) (err c "expected `=`"))
    (bump! c 1)
    (skip-ws! c)
    (tbl/assign! current path (read-value! c) pos)
    (end-of-line! c)))

(defn parse
  "Reads the TOML document `text` and returns its tagged tree (see
  `toml.data`).  Throws a parse error (see `toml.error`) for invalid input."
  [^String text]
  (when (and (pos? (.length text)) (== (int (.charAt text 0)) 0xFEFF))
    (fail "byte order mark" 0))
  (let [c (Cursor. text 0)
        root (tbl/new-table :explicit)]
    (loop [current root]
      (skip-ws! c)
      (let [ch (cur c)]
        (cond
          (== ch -1) nil
          (== ch 35) (do (skip-comment! c) (end-of-line! c) (recur current))
          (== ch 91) (recur (read-header! c root))
          :else
          (let [n (newline-len c)]
            (if (pos? n)
              (do (bump! c n) (recur current))
              (do (read-pair! c current) (recur current)))))))
    (tbl/freeze root)))
