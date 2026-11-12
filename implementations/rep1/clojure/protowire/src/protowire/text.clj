(ns protowire.text
  "Canonical text form of messages: printing ([[write-message!]], [[format-message]])
  and parsing ([[parse-message]]).

      message := \"{\" [ field ( \", \" field )* ] \"}\"
      field   := name \": \" value
      value   := integer | \"true\" | \"false\" | string | bytes | message | list
      list    := \"[\" [ value ( \", \" value )* ] \"]\"

  Printing emits fields in field-number order and omits default scalars and
  empty lists. Parsing accepts the relaxations described in the project
  README (arbitrary spaces between tokens, fields in any order, defaults
  given explicitly, ...)."
  (:require [protowire.error :as err]
            [protowire.hex :as hex]
            [protowire.schema :as schema]
            [protowire.types :as types])
  (:import (java.io ByteArrayOutputStream)
           (java.nio ByteBuffer)
           (java.nio.charset CharacterCodingException CodingErrorAction StandardCharsets)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* true)

(defn- code
  "UTF-16 code unit at index `i` of `s` as a long."
  ^long [^String s ^long i]
  (long (int (.charAt s i))))

;; ---------------------------------------------------------------- printing

(def ^:private hex-digits (char-array "0123456789abcdef"))

(defn- append-string! [^StringBuilder sb ^String s]
  (.append sb \")
  (let [n (.length s)
        ^chars hex-digits hex-digits]
    (loop [i 0 run 0]
      (if (< i n)
        (let [c (.charAt s i)
              x (int c)]
          (if (or (< x 0x20) (= x 0x7f) (= c \") (= c \\))
            (do (.append sb s (int run) (int i))
                (case x
                  34 (.append sb "\\\"")
                  92 (.append sb "\\\\")
                  10 (.append sb "\\n")
                  13 (.append sb "\\r")
                  9 (.append sb "\\t")
                  (do (.append sb "\\x")
                      (.append sb (aget hex-digits (bit-shift-right x 4)))
                      (.append sb (aget hex-digits (bit-and x 15)))))
                (recur (inc i) (inc i)))
            (recur (inc i) run)))
        (.append sb s (int run) (int n)))))
  (.append sb \"))

(declare append-message!)

(defn- append-value! [^StringBuilder sb field v]
  (case (:kind field)
    (:varint :fixed32 :fixed64)
    (if (identical? (:type field) :bool)
      (.append sb (if v "true" "false"))
      (if (instance? Long v) (.append sb (long v)) (.append sb (str v))))
    :string (append-string! sb v)
    :bytes (do (.append sb "x\"") (hex/append-hex! sb v) (.append sb \"))
    :message (append-message! sb (schema/field-message field) v)))

(defn- default-value? [field v]
  (case (:kind field)
    (:varint :fixed32 :fixed64) (if (identical? (:type field) :bool) (false? v) (and (instance? Long v) (zero? (long v))))
    :string (zero? (.length ^String v))
    :bytes (zero? (alength ^bytes v))
    :message false))

(defn append-message!
  "Appends the canonical text of message map `msg` (descriptor `desc`) to
  StringBuilder `sb`. Returns `sb`."
  [^StringBuilder sb desc msg]
  (.append sb \{)
  (let [fields (:fields desc)
        n (count fields)]
    (loop [i 0 first? true]
      (when (< i n)
        (let [field (nth fields i)
              v (get msg (:key field))
              emit? (cond (nil? v) false
                          (:repeated? field) (pos? (count v))
                          :else (not (default-value? field v)))]
          (if emit?
            (do (when-not first? (.append sb ", "))
                (.append sb ^String (:name field))
                (.append sb ": ")
                (if (:repeated? field)
                  (let [cnt (count v)]
                    (.append sb \[)
                    (dotimes [j cnt]
                      (when (pos? j) (.append sb ", "))
                      (append-value! sb field (nth v j)))
                    (.append sb \]))
                  (append-value! sb field v))
                (recur (inc i) false))
            (recur (inc i) first?))))))
  (.append sb \})
  sb)

(defn format-message
  "Canonical text of message map `msg` as a string."
  ^String [desc msg]
  (str (append-message! (StringBuilder.) desc msg)))

;; ----------------------------------------------------------------- parsing

(defn- skip-spaces! [^String s ^longs pos]
  (let [n (.length s)]
    (loop [p (aget pos 0)]
      (if (and (< p n) (= (.charAt s p) \space))
        (recur (inc p))
        (aset pos 0 p)))))

(defn- peek-char
  "Character at the cursor, or -1 at end of text."
  ^long [^String s ^longs pos]
  (let [p (aget pos 0)]
    (if (< p (.length s)) (code s p) -1)))

(defn- expect! [^String s ^longs pos ch]
  (if (= (peek-char s pos) (long (int (char ch))))
    (aset pos 0 (inc (aget pos 0)))
    (err/fail (str "expected '" ch "' at offset " (aget pos 0)))))

(defn- digit? [^long c] (and (>= c 48) (<= c 57)))

(defn- parse-integer
  "Parses `-?[1-9][0-9]*|0` at the cursor; returns a Long or BigInt (not yet
  range-checked)."
  [^String s ^longs pos]
  (let [start (aget pos 0)
        neg? (= (peek-char s pos) 45)
        p0 (if neg? (inc start) start)
        n (.length s)]
    (when-not (digit? (if (< p0 n) (code s p0) -1)) (err/fail "expected integer"))
    (let [p1 (loop [p p0] (if (and (< p n) (digit? (code s p))) (recur (inc p)) p))
          cnt (- p1 p0)]
      (when (and (> cnt 1) (= (.charAt s p0) \0)) (err/fail "leading zeros"))
      (when (and neg? (= cnt 1) (= (.charAt s p0) \0)) (err/fail "negative zero"))
      (when (> cnt 20) (err/fail "integer out of range"))
      (aset pos 0 (long p1))
      (if (<= cnt 18)
        (let [v (loop [p p0 acc 0]
                  (if (< p p1) (recur (inc p) (+ (* acc 10) (- (code s p) 48))) acc))]
          (if neg? (- v) v))
        (let [b (java.math.BigInteger. (subs s p0 p1))
              b (if neg? (.negate b) b)]
          (if (and (<= (.compareTo b (java.math.BigInteger/valueOf Long/MAX_VALUE)) 0)
                   (>= (.compareTo b (java.math.BigInteger/valueOf Long/MIN_VALUE)) 0))
            (.longValue b)
            (clojure.lang.BigInt/fromBigInteger b)))))))

(defn- parse-bool [^String s ^longs pos]
  (let [p (aget pos 0)]
    (cond (.startsWith s "true" (int p)) (do (aset pos 0 (+ p 4)) true)
          (.startsWith s "false" (int p)) (do (aset pos 0 (+ p 5)) false)
          :else (err/fail "expected boolean"))))

(defn- hex-val ^long [^long c]
  (cond (and (>= c 48) (<= c 57)) (- c 48)
        (and (>= c 97) (<= c 102)) (- c 87)
        (and (>= c 65) (<= c 70)) (- c 55)
        :else -1))

(defn- decode-utf8 ^String [^bytes b]
  (try
    (str (.decode (doto (.newDecoder StandardCharsets/UTF_8)
                    (.onMalformedInput CodingErrorAction/REPORT)
                    (.onUnmappableCharacter CodingErrorAction/REPORT))
                  (ByteBuffer/wrap b)))
    (catch CharacterCodingException _ (err/fail "invalid UTF-8 in string literal"))))

(defn- parse-string
  "Parses a string literal at the cursor; returns a String. Fast path for
  literals without escapes."
  [^String s ^longs pos]
  (expect! s pos \")
  (let [n (.length s)
        start (aget pos 0)
        ;; scan to the closing quote or first backslash
        stop (long (loop [p start]
               (if (>= p n)
                 (err/fail "unterminated string")
                 (let [c (.charAt s p)]
                   (cond (or (= c \") (= c \\)) p
                         (< (int c) 0x20) (err/fail "control character in string")
                         :else (recur (inc p)))))))]
    (if (= (.charAt s stop) \")
      (do (aset pos 0 (inc stop)) (subs s start stop))
      ;; slow path: build bytes
      (let [out (ByteArrayOutputStream.)
            flush-run! (fn [^long from ^long to]
                         (when (< from to)
                           (.write out (.getBytes (subs s from to) StandardCharsets/UTF_8))))]
        (loop [p stop run start]
          (when (>= p n) (err/fail "unterminated string"))
          (let [c (.charAt s p)]
            (cond
              (= c \") (do (flush-run! run p)
                           (aset pos 0 (inc p))
                           (decode-utf8 (.toByteArray out)))
              (= c \\)
              (do (flush-run! run p)
                  (when (>= (inc p) n) (err/fail "unterminated string"))
                  (let [e (.charAt s (inc p))]
                    (case e
                      \" (do (.write out 34) (recur (+ p 2) (+ p 2)))
                      \\ (do (.write out 92) (recur (+ p 2) (+ p 2)))
                      \n (do (.write out 10) (recur (+ p 2) (+ p 2)))
                      \r (do (.write out 13) (recur (+ p 2) (+ p 2)))
                      \t (do (.write out 9) (recur (+ p 2) (+ p 2)))
                      \x (do (when (>= (+ p 3) n) (err/fail "bad \\x escape"))
                             (let [h (hex-val (code s (+ p 2)))
                                   l (hex-val (code s (+ p 3)))]
                               (when (or (neg? h) (neg? l)) (err/fail "bad \\x escape"))
                               (.write out (int (+ (* 16 h) l)))
                               (recur (+ p 4) (+ p 4))))
                      (err/fail "unknown escape"))))
              (< (int c) 0x20) (err/fail "control character in string")
              :else (recur (inc p) run))))))))

(defn- parse-bytes
  "Parses `x\"<lowercase hex>\"` at the cursor; returns a byte array."
  ^bytes [^String s ^longs pos]
  (expect! s pos \x)
  (expect! s pos \")
  (let [start (aget pos 0)
        n (.length s)
        stop (long (loop [p start]
                     (cond (>= p n) (err/fail "unterminated bytes literal")
                           (= (.charAt s p) \") p
                           :else (recur (inc p)))))]
    (aset pos 0 (inc stop))
    (hex/hex->bytes s start stop)))

(declare parse-message)

(defn- parse-scalar-or-message [^String s ^longs pos field]
  (case (:kind field)
    (:varint :fixed32 :fixed64)
    (let [type (:type field)]
      (if (identical? type :bool)
        (parse-bool s pos)
        (types/check-value type (parse-integer s pos))))
    :string (parse-string s pos)
    :bytes (parse-bytes s pos)
    :message (parse-message s pos (schema/field-message field))))

(defn- parse-field-value [^String s ^longs pos field]
  (if (:repeated? field)
    (do
      (expect! s pos \[)
      (skip-spaces! s pos)
      (if (= (peek-char s pos) 93)
        (do (aset pos 0 (inc (aget pos 0))) [])
        (loop [acc (transient [])]
          (skip-spaces! s pos)
          (let [acc (conj! acc (parse-scalar-or-message s pos field))]
            (skip-spaces! s pos)
            (case (peek-char s pos)
              44 (do (aset pos 0 (inc (aget pos 0))) (recur acc))
              93 (do (aset pos 0 (inc (aget pos 0))) (persistent! acc))
              (err/fail "expected ',' or ']'"))))))
    (parse-scalar-or-message s pos field)))

(defn- parse-name [^String s ^longs pos]
  (let [start (aget pos 0)
        n (.length s)
        end (long (loop [p start]
              (if (and (< p n)
                       (let [c (int (.charAt s p))]
                         (or (and (>= c 48) (<= c 57)) (and (>= c 65) (<= c 90))
                             (and (>= c 97) (<= c 122)) (= c 95))))
                (recur (inc p))
                p)))]
    (when (= start end) (err/fail "expected field name"))
    (aset pos 0 end)
    (subs s start end)))

(defn parse-message
  "Parses one message (`{ ... }`) at the cursor `pos` of `s` for descriptor
  `desc`; returns the message map. Spaces before the opening brace are
  skipped; the cursor is left just after the closing brace."
  [^String s ^longs pos desc]
  (skip-spaces! s pos)
  (expect! s pos \{)
  (skip-spaces! s pos)
  (if (= (peek-char s pos) 125)
    (do (aset pos 0 (inc (aget pos 0))) {})
    (let [by-name (:by-name desc)]
      (loop [m (transient {})]
        (skip-spaces! s pos)
        (let [fname (parse-name s pos)
              field (or (get by-name fname) (err/fail (str "unknown field " fname)))
              k (:key field)]
          (when (contains? m k) (err/fail (str "duplicate field " fname)))
          (skip-spaces! s pos)
          (expect! s pos \:)
          (skip-spaces! s pos)
          (let [m (assoc! m k (parse-field-value s pos field))]
            (skip-spaces! s pos)
            (case (peek-char s pos)
              44 (do (aset pos 0 (inc (aget pos 0))) (recur m))
              125 (do (aset pos 0 (inc (aget pos 0))) (persistent! m))
              (err/fail "expected ',' or '}'"))))))))

(defn parse
  "Parses the whole string `s` as one message of descriptor `desc`, allowing
  spaces around it. Throws a protowire error otherwise."
  [^String s desc]
  (let [pos (long-array 1)
        m (parse-message s pos desc)]
    (skip-spaces! s pos)
    (when (< (aget pos 0) (.length s)) (err/fail "trailing text after message"))
    m))
