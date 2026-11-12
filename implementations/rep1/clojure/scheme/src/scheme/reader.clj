(ns scheme.reader
  "Recursive-descent reader: text to datums (see SPEC.md, \"Lexical syntax\").

  Datums are the runtime values themselves: Longs/Bignums, Booleans, Strings,
  interned `Sym`s, and `Pair`s ending in `NIL`."
  (:require [scheme.number :as num]
            [scheme.types :as t])
  (:import [scheme.types Pair]))

(set! *warn-on-reflection* true)

(def eof "Returned by `read-datum` when the input is exhausted." (Object.))

(defn- syntax-error [msg]
  (ex-info msg {:scheme/syntax-error msg}))

(defn syntax-error?
  "True if `e` was thrown for malformed program text."
  [^Throwable e]
  (contains? (ex-data e) :scheme/syntax-error))

(defn reader
  "A reader over the string `src`."
  [^String src]
  {:src src :pos (long-array 1)})

(defn- whitespace? [c] (or (== c 32) (== c 9) (== c 13) (== c 10)))

(defn- delimiter? [c]
  (or (whitespace? c) (== c 40) (== c 41) (== c 39) (== c 34) (== c 59)))

(defn- skip-comment
  "Index of the LF ending the comment that starts at `i` (or end of input)."
  ^long [^String s ^long i]
  (loop [j i]
    (if (and (< j (.length s)) (not= (.charAt s j) \newline))
      (recur (inc j))
      j)))

(defn- skip-blanks!
  "Skip whitespace and comments; return the next char code or -1 at the end."
  ^long [^String s ^longs pos]
  (loop [i (aget pos 0)]
    (if (>= i (.length s))
      (do (aset pos 0 i) -1)
      (let [c (long (.charAt s i))]
        (cond
          (whitespace? c) (recur (inc i))
          (== c 59) (recur (skip-comment s i))
          :else (do (aset pos 0 i) c))))))

(defn- digit? [c] (and (>= c 48) (<= c 57)))

(defn- integer-token? [^String tok]
  (let [n (.length tok)
        start (if (and (pos? n) (contains? #{\+ \-} (.charAt tok 0))) 1 0)]
    (and (> n start)
         (loop [i start]
           (cond (== i n) true
                 (digit? (long (.charAt tok i))) (recur (inc i))
                 :else false)))))

(defn- parse-atom [^String tok]
  (cond
    (= tok "#t") true
    (= tok "#f") false
    (integer-token? tok) (num/parse-integer tok)
    :else (t/intern-sym tok)))

(defn- read-token [^String s ^longs pos]
  (let [start (aget pos 0)
        end (loop [i start]
              (if (and (< i (.length s)) (not (delimiter? (long (.charAt s i)))))
                (recur (inc i))
                i))]
    (aset pos 0 end)
    (.substring s start end)))

(defn- read-string-literal [^String s ^longs pos]
  (let [sb (StringBuilder.)
        n (.length s)]
    (loop [i (inc (aget pos 0))]
      (when (>= i n) (throw (syntax-error "unterminated string")))
      (let [c (.charAt s i)]
        (cond
          (= c \") (do (aset pos 0 (inc i)) (.toString sb))
          (= c \\) (do (when (>= (inc i) n) (throw (syntax-error "unterminated string")))
                       (let [e (.charAt s (inc i))]
                         (.append sb (case e \n \newline \t \tab e))
                         (recur (+ i 2))))
          :else (do (.append sb c) (recur (inc i))))))))

(declare read-form)

(defn- lone-dot? [^String s ^longs pos]
  (let [i (aget pos 0)]
    (and (== (long (.charAt s i)) 46)
         (or (== (inc i) (.length s))
             (delimiter? (long (.charAt s (inc i))))))))

(defn- read-list-tail [^String s ^longs pos]
  (loop [items (transient [])]
    (let [c (skip-blanks! s pos)]
      (cond
        (== c -1) (throw (syntax-error "unterminated list"))
        (== c 41) (do (aset pos 0 (inc (aget pos 0)))
                      (t/vector->list (persistent! items)))
        (lone-dot? s pos)
        (do (aset pos 0 (inc (aget pos 0)))
            (let [tail (read-form s pos)]
              (when-not (== (skip-blanks! s pos) 41)
                (throw (syntax-error "expected ) after dotted tail")))
              (aset pos 0 (inc (aget pos 0)))
              (t/vector->list (persistent! items) tail)))
        :else (recur (conj! items (read-form s pos)))))))

(defn- read-form [^String s ^longs pos]
  (let [c (skip-blanks! s pos)]
    (cond
      (== c -1) (throw (syntax-error "unexpected end of input"))
      (== c 40) (do (aset pos 0 (inc (aget pos 0))) (read-list-tail s pos))
      (== c 41) (throw (syntax-error "unexpected )"))
      (== c 39) (do (aset pos 0 (inc (aget pos 0)))
                    (let [d (read-form s pos)]
                      (t/cons-pair (t/intern-sym "quote") (t/cons-pair d t/NIL))))
      (== c 34) (read-string-literal s pos)
      :else (parse-atom (read-token s pos)))))

(defn read-datum
  "Read the next datum from reader `r`, or return `eof`."
  [{:keys [^String src ^longs pos]}]
  (if (== (skip-blanks! src pos) -1)
    eof
    (read-form src pos)))

(defn read-all
  "All datums of the string `src`, as a vector."
  [^String src]
  (let [r (reader src)]
    (loop [acc []]
      (let [d (read-datum r)]
        (if (identical? d eof) acc (recur (conj acc d)))))))
