(ns json.parse
  "A strict RFC 8259 JSON parser over UTF-8 bytes.

  The parser is a single forward recursive-descent pass with no
  backtracking. The input must already be well-formed UTF-8 (see
  [[json.utf8/valid?]]); [[parse-bytes]] checks that first. Failures are
  reported by throwing an `ex-info` whose data has `:type ::invalid` and the
  byte offset `:pos` (see [[invalid?]])."
  (:require [json.tree :as tree]
            [json.utf8 :as utf8])
  (:import (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def ^:const max-depth
  "Deepest permitted nesting of arrays and objects."
  512)

(defn invalid?
  "True if `e` is the exception thrown for a malformed document."
  [e]
  (and (instance? clojure.lang.ExceptionInfo e)
       (= ::invalid (:type (ex-data e)))))

(defn- fail!
  [^String msg ^long pos]
  (throw (ex-info (str "invalid JSON: " msg " at byte " pos)
                  {:type ::invalid :pos pos})))

(defn- fail-at!
  "Like [[fail!]] but typed as returning a long, for use in primitive code."
  ^long [^String msg ^long pos]
  (fail! msg pos)
  0)

;; The cursor is a one-element long array so that helper functions can advance
;; it without boxing.

(defn- cur
  "Unsigned byte at the cursor, or -1 at the end of input."
  ^long [^bytes buf ^longs pos]
  (let [i (aget pos 0)]
    (if (< i (alength buf))
      (bit-and (long (aget buf i)) 0xFF)
      -1)))

(defn- skip-ws!
  [^bytes buf ^longs pos]
  (let [n (alength buf)]
    (loop [i (aget pos 0)]
      (if (< i n)
        (let [b (bit-and (long (aget buf i)) 0xFF)]
          (if (or (== b 0x20) (== b 0x09) (== b 0x0A) (== b 0x0D))
            (recur (inc i))
            (aset pos 0 i)))
        (aset pos 0 i)))))

(defn- expect!
  "Consumes byte `c` or fails."
  [^bytes buf ^longs pos ^long c ^String what]
  (if (== (cur buf pos) c)
    (aset pos 0 (inc (aget pos 0)))
    (fail! (str "expected " what) (aget pos 0))))

(defn- literal!
  "Consumes the ASCII word `word` or fails; returns `value`."
  [^bytes buf ^longs pos ^String word value]
  (let [start (aget pos 0)
        len   (.length word)]
    (when (> (+ start len) (alength buf))
      (fail! "bad literal" start))
    (dotimes [k len]
      (when-not (== (bit-and (long (aget buf (+ start k))) 0xFF)
                    (long (int (.charAt word k))))
        (fail! "bad literal" start)))
    (aset pos 0 (+ start len))
    value))

;; ---------------------------------------------------------------- strings

(defn- hex-digit
  "Value of ASCII hex digit byte `b`, or -1."
  ^long [^long b]
  (cond
    (and (>= b 0x30) (<= b 0x39)) (- b 0x30)
    (and (>= b 0x41) (<= b 0x46)) (- b 0x37)
    (and (>= b 0x61) (<= b 0x66)) (- b 0x57)
    :else -1))

(defn- hex4
  "Value of the four hex digits at index `i`, or -1 if they are missing or
  malformed."
  ^long [^bytes buf ^long i]
  (if (> (+ i 4) (alength buf))
    -1
    (loop [k 0 acc 0]
      (if (== k 4)
        acc
        (let [d (hex-digit (bit-and (long (aget buf (+ i k))) 0xFF))]
          (if (neg? d)
            -1
            (recur (inc k) (+ (* acc 16) d))))))))

(defn- slice
  ^String [^bytes buf ^long from ^long to]
  (String. buf (int from) (int (- to from)) StandardCharsets/UTF_8))

(defn- read-escape!
  "Decodes the escape whose backslash is at `i`, appends it to `sb` and
  returns the index after it."
  ^long [^bytes buf ^StringBuilder sb ^long i]
  (let [n (alength buf)
        e (if (< (inc i) n) (bit-and (long (aget buf (inc i))) 0xFF) -1)
        simple (fn [c] (.append sb (char c)) (+ i 2))]
    (case e
      34 (simple 34)
      92 (simple 92)
      47 (simple 47)
      98 (simple 8)
      102 (simple 12)
      110 (simple 10)
      114 (simple 13)
      116 (simple 9)
      117 (let [hi (hex4 buf (+ i 2))]
            (cond
              (neg? hi) (fail! "bad \\u escape" i)

              (and (>= hi 0xD800) (<= hi 0xDBFF))
              (let [j (+ i 6)]
                (if (and (< (inc j) n)
                         (== (long (aget buf j)) 92)
                         (== (long (aget buf (inc j))) 117))
                  (let [lo (hex4 buf (+ j 2))]
                    (if (and (>= lo 0xDC00) (<= lo 0xDFFF))
                      (do (.append sb (char hi))
                          (.append sb (char lo))
                          (+ j 6))
                      (fail! "high surrogate not followed by low surrogate" i)))
                  (fail! "high surrogate not followed by low surrogate" i)))

              (and (>= hi 0xDC00) (<= hi 0xDFFF))
              (fail! "lone low surrogate" i)

              :else (do (.append sb (char hi)) (+ i 6))))
      (fail! "bad escape" i))))

(defn- parse-string!
  "Parses the string whose opening quote is at the cursor."
  ^String [^bytes buf ^longs pos]
  (let [n     (alength buf)
        start (inc (aget pos 0))]
    ;; Fast path: scan to the closing quote; an escape drops to the slow path.
    (loop [i start]
      (if (>= i n)
        (fail! "unterminated string" (dec start))
        (let [b (bit-and (long (aget buf i)) 0xFF)]
          (cond
            (== b 0x22) (do (aset pos 0 (inc i))
                            (slice buf start i))
            (< b 0x20)  (fail! "control character in string" i)
            (== b 0x5C) (let [sb (StringBuilder.)]
                          (.append sb (slice buf start i))
                          (loop [i i run i]
                            (if (>= i n)
                              (fail! "unterminated string" (dec start))
                              (let [b (bit-and (long (aget buf i)) 0xFF)]
                                (cond
                                  (== b 0x22)
                                  (do (.append sb (slice buf run i))
                                      (aset pos 0 (inc i))
                                      (.toString sb))

                                  (< b 0x20)
                                  (fail! "control character in string" i)

                                  (== b 0x5C)
                                  (do (.append sb (slice buf run i))
                                      (let [j (read-escape! buf sb i)]
                                        (recur j j)))

                                  :else (recur (inc i) run))))))
            :else (recur (inc i))))))))

;; ---------------------------------------------------------------- numbers

(defn- digits!
  "Advances over one or more ASCII digits starting at `i`; returns the index
  after them, failing if there is none."
  ^long [^bytes buf ^long i]
  (let [n (alength buf)]
    (loop [j i]
      (if (and (< j n)
               (let [b (long (aget buf j))] (and (>= b 0x30) (<= b 0x39))))
        (recur (inc j))
        (if (== j i)
          (fail-at! "expected digit" i)
          j)))))

(defn- digit-at? [^bytes buf ^long i]
  (and (< i (alength buf))
       (let [b (long (aget buf i))] (and (>= b 0x30) (<= b 0x39)))))

(defn- byte-at ^long [^bytes buf ^long i]
  (if (< i (alength buf)) (bit-and (long (aget buf i)) 0xFF) -1))

(defn- ascii [^bytes buf ^long from ^long to]
  (String. buf (int from) (int (- to from)) StandardCharsets/ISO_8859_1))

(defn- parse-number!
  "Parses a number at the cursor and returns a number node holding its
  canonical text: integer lexemes verbatim, otherwise the mantissa verbatim
  followed by the exponent as `e`, optional `-`, digits without leading
  zeros."
  [^bytes buf ^longs pos]
  (let [start (aget pos 0)
        i     (if (== (byte-at buf start) 0x2D) (inc start) start)
        ;; int part
        i     (long (cond
                      (== (byte-at buf i) 0x30) (inc i)
                      (digit-at? buf i)         (digits! buf i)
                      :else (fail-at! "expected digit" i)))
        ;; frac part
        i     (long (if (== (byte-at buf i) 0x2E)
                      (digits! buf (inc i))
                      i))
        mant-end i
        e     (byte-at buf i)]
    (if (or (== e 0x65) (== e 0x45))
      (let [s       (inc i)
            sign    (byte-at buf s)
            neg?    (== sign 0x2D)
            ds      (long (if (or neg? (== sign 0x2B)) (inc s) s))
            de      (digits! buf ds)
            nz      (long (loop [k ds]       ; first non-zero exponent digit
                            (if (and (< k de) (== (long (aget buf k)) 0x30))
                              (recur (inc k))
                              k)))
            sb      (StringBuilder. (int (+ (- mant-end start) (- de nz) 3)))]
        (.append sb (ascii buf start mant-end))
        (.append sb \e)
        (if (== nz de)
          (.append sb \0)
          (do (when neg? (.append sb \-))
              (.append sb (ascii buf nz de))))
        (aset pos 0 de)
        (tree/num-node (.toString sb)))
      (do (aset pos 0 mant-end)
          (tree/num-node (ascii buf start mant-end))))))

;; ------------------------------------------------------------- containers

(declare parse-value!)

(defn- check-depth! [^longs pos ^long depth]
  (when (> depth max-depth)
    (fail! "nesting too deep" (aget pos 0))))

(defn- parse-array!
  [^bytes buf ^longs pos ^long depth]
  (check-depth! pos depth)
  (aset pos 0 (inc (aget pos 0)))
  (skip-ws! buf pos)
  (if (== (cur buf pos) 0x5D)
    (do (aset pos 0 (inc (aget pos 0))) [])
    (loop [v (transient [])]
      (skip-ws! buf pos)
      (let [v (conj! v (parse-value! buf pos depth))]
        (skip-ws! buf pos)
        (let [c (cur buf pos)]
          (cond
            (== c 0x2C) (do (aset pos 0 (inc (aget pos 0))) (recur v))
            (== c 0x5D) (do (aset pos 0 (inc (aget pos 0))) (persistent! v))
            :else (fail! "expected ',' or ']'" (aget pos 0))))))))

(defn- parse-object!
  [^bytes buf ^longs pos ^long depth]
  (check-depth! pos depth)
  (aset pos 0 (inc (aget pos 0)))
  (skip-ws! buf pos)
  (if (== (cur buf pos) 0x7D)
    (do (aset pos 0 (inc (aget pos 0))) (tree/obj-node []))
    (loop [v (transient [])]
      (skip-ws! buf pos)
      (when-not (== (cur buf pos) 0x22)
        (fail! "expected string key" (aget pos 0)))
      (let [k (parse-string! buf pos)]
        (skip-ws! buf pos)
        (expect! buf pos 0x3A ":")
        (skip-ws! buf pos)
        (let [x (parse-value! buf pos depth)
              v (conj! v (clojure.lang.MapEntry/create k x))]
          (skip-ws! buf pos)
          (let [c (cur buf pos)]
            (cond
              (== c 0x2C) (do (aset pos 0 (inc (aget pos 0))) (recur v))
              (== c 0x7D) (do (aset pos 0 (inc (aget pos 0)))
                              (tree/obj-node (persistent! v)))
              :else (fail! "expected ',' or '}'" (aget pos 0)))))))))

(defn- parse-value!
  "Parses the value at the cursor. `depth` is the nesting depth of the
  enclosing container (0 at top level)."
  [^bytes buf ^longs pos ^long depth]
  (let [c (cur buf pos)]
    (case c
      123 (parse-object! buf pos (inc depth))
      91  (parse-array! buf pos (inc depth))
      34  (parse-string! buf pos)
      116 (literal! buf pos "true" true)
      102 (literal! buf pos "false" false)
      110 (literal! buf pos "null" nil)
      (if (or (== c 0x2D) (and (>= c 0x30) (<= c 0x39)))
        (parse-number! buf pos)
        (fail! "unexpected character" (aget pos 0))))))

(defn parse-bytes
  "Parses `buf`, a byte array holding exactly one JSON document, and returns
  its tree (see [[json.tree]]). Throws an exception satisfying [[invalid?]] if
  the bytes are not strictly valid UTF-8 or not a valid document."
  [^bytes buf]
  (when-not (utf8/valid? buf)
    (fail! "malformed UTF-8" 0))
  (let [pos (long-array 1)]
    (skip-ws! buf pos)
    (let [v (parse-value! buf pos 0)]
      (skip-ws! buf pos)
      (when (< (aget pos 0) (alength buf))
        (fail! "unexpected trailing content" (aget pos 0)))
      v)))
