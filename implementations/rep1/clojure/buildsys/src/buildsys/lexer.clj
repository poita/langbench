(ns buildsys.lexer
  "The Kiln Build Language lexer.

  Three stages share one *literal scanner* ([[skip-literal]]) so they can never
  disagree about what lies inside a string literal:

  1. comment stripping, 2. logical-line assembly by bracket depth, and
  3. tokenisation.

  [[lex]] runs all three over a whole build file and returns its logical lines.
  Tokens are two-element vectors `[kind value]`:

  | kind   | value                                   |
  |--------|-----------------------------------------|
  | `:id`  | identifier text                         |
  | `:int` | a long                                  |
  | `:str` | the raw literal text, quotes included   |
  | `:op`  | punctuation / operator text, e.g. `\"|>\"` |"
  (:require [buildsys.error :as err]))

(set! *warn-on-reflection* true)

(declare skip-literal)

(defn skip-region
  "Skip an interpolation region.  `j` is the index just after the opening
  `{`.  Returns the index just after the matching `}`, or nil when the string
  ends first."
  [^String s j]
  (let [n (.length s)]
    (loop [j j depth 1]
      (when (< j n)
        (let [c (.charAt s j)]
          (cond
            (or (= c \") (= c \'))
            (when-let [e (skip-literal s j)] (recur (long e) depth))
            (= c \{) (recur (inc j) (inc depth))
            (= c \}) (if (= depth 1) (inc j) (recur (inc j) (dec depth)))
            :else (recur (inc j) depth)))))))

(defn skip-literal
  "The literal scanner.  `s.charAt(i)` is an opening quote; returns the index
  just after the closing quote, or nil when the string ends first."
  [^String s i]
  (let [n (.length s)]
    (if (= \' (.charAt s i))
      (loop [j (inc i)]
        (when (< j n)
          (if (= \' (.charAt s j))
            (if (and (< (inc j) n) (= \' (.charAt s (inc j))))
              (recur (+ j 2))
              (inc j))
            (recur (inc j)))))
      (loop [j (inc i)]
        (when (< j n)
          (let [c (.charAt s j)]
            (case c
              \\ (recur (+ j 2))
              \" (inc j)
              \{ (if (and (< (inc j) n) (= \{ (.charAt s (inc j))))
                   (recur (+ j 2))
                   (when-let [e (skip-region s (inc j))]
                     (recur (long e))))
              (recur (inc j)))))))))

(defn- strip-trailing ^String [^String s]
  (loop [e (.length s)]
    (if (and (pos? e) (#{\space \tab} (.charAt s (dec e))))
      (recur (dec e))
      (subs s 0 e))))

(defn- scan-line
  "Stages 1 and 2 for one physical line.  Returns `[text depth']` where `text`
  is the line with comment and trailing blanks removed.  `fail!` is called
  (and must throw) on an unterminated literal or negative bracket depth."
  [^String s depth fail!]
  (let [n (.length s)]
    (loop [i 0 depth depth]
      (if (>= i n)
        [(strip-trailing s) depth]
        (let [c (.charAt s i)]
          (case c
            (\" \') (if-let [e (skip-literal s i)]
                      (recur (long e) depth)
                      (fail!))
            \# [(strip-trailing (subs s 0 i)) depth]
            (\( \[) (recur (inc i) (inc depth))
            (\) \]) (if (zero? depth) (fail!) (recur (inc i) (dec depth)))
            (recur (inc i) depth)))))))

(def ^:private two-char-ops #{"|>" "||" "&&" "==" "!=" "<=" ">=" "++"})
(def ^:private one-char-ops #{\( \) \[ \] \{ \} \, \= \~ \+ \- \* \/ \% \! \< \>})

(defn tokenize
  "Stage 3: split `text` into tokens.  `fail!` is called (and must throw) on a
  byte that cannot begin a token."
  [^String text fail!]
  (let [n (.length text)]
    (loop [i 0 out (transient [])]
      (if (>= i n)
        (persistent! out)
        (let [c (.charAt text i)]
          (cond
            (or (= c \space) (= c \tab)) (recur (inc i) out)

            (or (<= (int \a) (int c) (int \z))
                (<= (int \A) (int c) (int \Z))
                (= c \_))
            (let [e (loop [j (inc i)]
                      (if (and (< j n)
                               (let [d (.charAt text j)]
                                 (or (<= (int \a) (int d) (int \z))
                                     (<= (int \A) (int d) (int \Z))
                                     (<= (int \0) (int d) (int \9))
                                     (= d \_))))
                        (recur (inc j))
                        j))]
              (recur (long e) (conj! out [:id (subs text i e)])))

            (<= (int \0) (int c) (int \9))
            (let [e (loop [j (inc i)]
                      (if (and (< j n) (<= (int \0) (int (.charAt text j)) (int \9)))
                        (recur (inc j))
                        j))]
              (recur (long e)
                     (conj! out [:int (.longValue (java.math.BigInteger. (subs text i e)))])))

            (or (= c \") (= c \'))
            (if-let [e (skip-literal text i)]
              (recur (long e) (conj! out [:str (subs text i e)]))
              (fail!))

            :else
            (let [two (when (< (inc i) n) (subs text i (+ i 2)))]
              (cond
                (and two (two-char-ops two)) (recur (+ i 2) (conj! out [:op two]))
                (one-char-ops c) (recur (inc i) (conj! out [:op (str c)]))
                :else (fail!)))))))))

(defn- blank? [^String s]
  (every? #{\space \tab} s))

(defn lex
  "Lex build file `text` (named `file` in errors) into a vector of logical
  lines `{:line n :tokens [...]}`.  Throws `E_PARSE` for the first lexical
  error, in file order."
  [file ^String text]
  (let [raw ^objects (.split text "\n" -1)
        ;; a final newline yields a trailing empty piece that is not a line
        ^objects physical (if (and (pos? (alength raw))
                                   (= "" (aget raw (dec (alength raw)))))
                            (java.util.Arrays/copyOf raw (dec (alength raw)))
                            raw)
        total (alength physical)]
    (loop [idx 0 start 0 depth (Long/valueOf 0) buf nil out []]
      (if (>= idx total)
        (if (pos? depth)
          (err/parse-error file start)
          out)
        (let [lineno (if buf start (inc idx))
              fail! #(err/parse-error file lineno)
              [text' depth'] (scan-line (aget physical idx) depth fail!)
              buf' (if buf (str buf " " text') text')]
          (if (zero? depth')
            (recur (inc idx) (inc idx) 0 nil
                   (if (blank? buf')
                     out
                     (conj out {:line lineno
                                :tokens (tokenize buf' fail!)})))
            (recur (inc idx) (if buf start (inc idx)) depth' buf' out)))))))
