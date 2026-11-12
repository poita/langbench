(ns buildsys.lexer
  "KBL lexing: comment stripping, logical-line assembly and tokenisation, plus
  the reader for string literals.

  One *literal scanner* (`skip-sq`, `skip-dq`, `skip-interp`) is shared by
  every stage so that they can never disagree about where a string literal
  ends.

  A token is a vector `[kind value]`, where kind is one of
    :id   identifier text            :int  a long
    :str  the raw literal incl. quotes   :sym  punctuation or operator text"
  (:require [buildsys.errors :as e]
            [clojure.string :as str]))

(set! *warn-on-reflection* true)

(def reserved-words
  "Identifiers that cannot be used as variable, parameter or rule names."
  #{"abort" "after" "cmd" "cost" "default" "depfile" "each" "elsewhen" "false"
    "in" "include" "let" "otherwise" "out" "phony" "rule" "set" "step" "true"
    "use" "when"})

;; ------------------------------------------------------------ literal scanner

(declare skip-dq)

(defn- skip-sq
  "Index just past the single-quoted literal starting at `i`."
  ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [j (inc i)]
      (cond
        (>= j n) (e/parse-fail!)
        (= \' (.charAt s j))
        (if (and (< (inc j) n) (= \' (.charAt s (inc j)))) (recur (+ j 2)) (inc j))
        :else (recur (inc j))))))

(defn- skip-interp
  "Index just past the `}` closing the interpolation whose body starts at `i`."
  ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [j i depth 1]
      (if (>= j n)
        (e/parse-fail!)
        (let [c (.charAt s j)]
          (cond
            (= c \") (recur (long (skip-dq s j)) depth)
            (= c \') (recur (long (skip-sq s j)) depth)
            (= c \{) (recur (inc j) (inc depth))
            (= c \}) (if (= depth 1) (inc j) (recur (inc j) (dec depth)))
            :else (recur (inc j) depth)))))))

(defn- skip-dq
  "Index just past the double-quoted literal starting at `i`."
  ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [j (inc i)]
      (if (>= j n)
        (e/parse-fail!)
        (let [c (.charAt s j)]
          (cond
            (= c \\) (recur (+ j 2))
            (= c \{) (if (and (< (inc j) n) (= \{ (.charAt s (inc j))))
                       (recur (+ j 2))
                       (recur (skip-interp s (inc j))))
            (= c \}) (if (and (< (inc j) n) (= \} (.charAt s (inc j))))
                       (recur (+ j 2))
                       (recur (inc j)))
            (= c \") (inc j)
            :else (recur (inc j))))))))

;; --------------------------------------------------------- stage 1 and 2 scan

(defn- strip-trailing ^String [^String s]
  (loop [n (.length s)]
    (if (and (pos? n) (let [c (.charAt s (dec n))] (or (= c \space) (= c \tab))))
      (recur (dec n))
      (subs s 0 n))))

(defn- scan-line
  "Scans one physical line with the literal scanner.  Returns
  `[text-without-comment bracket-depth]`."
  [^String s ^long depth]
  (let [n (.length s)]
    (loop [i 0 depth depth]
      (if (>= i n)
        [(strip-trailing s) depth]
        (let [c (.charAt s i)]
          (cond
            (= c \") (recur (long (skip-dq s i)) depth)
            (= c \') (recur (long (skip-sq s i)) depth)
            (= c \#) [(strip-trailing (subs s 0 i)) depth]
            (or (= c \() (= c \[)) (recur (inc i) (inc depth))
            (or (= c \)) (= c \]))
            (if (zero? depth) (e/parse-fail!) (recur (inc i) (dec depth)))
            :else (recur (inc i) depth)))))))

;; ------------------------------------------------------------- tokenisation

(defn- ident-start? [c] (or (<= (int \a) c (int \z)) (<= (int \A) c (int \Z)) (= c (int \_))))
(defn- digit? [c] (<= (int \0) c (int \9)))
(defn- ident-part? [c] (or (ident-start? c) (digit? c)))

(def ^:private two-char-ops #{"|>" "||" "&&" "==" "!=" "<=" ">=" "++"})
(def ^:private one-char-syms #{\( \) \[ \] \{ \} \, \= \< \> \~ \+ \- \* \/ \% \!})

(defn- parse-int [^String t]
  (try (Long/parseLong t)
       (catch NumberFormatException _ (.longValue (java.math.BigInteger. t)))))

(defn tokenize
  "Splits the text of one logical line (or interpolation body) into tokens."
  [^String s]
  (let [n (.length s)]
    (loop [i 0 out (transient [])]
      (if (>= i n)
        (persistent! out)
        (let [c (.charAt s i) ci (int c)]
          (cond
            (or (= c \space) (= c \tab)) (recur (inc i) out)

            (ident-start? ci)
            (let [j (long (loop [j (inc i)]
                      (if (and (< j n) (ident-part? (int (.charAt s j)))) (recur (inc j)) j)))]
              (recur j (conj! out [:id (subs s i j)])))

            (digit? ci)
            (let [j (long (loop [j (inc i)]
                      (if (and (< j n) (digit? (int (.charAt s j)))) (recur (inc j)) j)))]
              (recur j (conj! out [:int (parse-int (subs s i j))])))

            (= c \") (let [j (long (skip-dq s i))] (recur j (conj! out [:str (subs s i j)])))
            (= c \') (let [j (long (skip-sq s i))] (recur j (conj! out [:str (subs s i j)])))

            (and (< (inc i) n) (two-char-ops (subs s i (+ i 2))))
            (recur (+ i 2) (conj! out [:sym (subs s i (+ i 2))]))

            (one-char-syms c) (recur (inc i) (conj! out [:sym (str c)]))

            :else (e/parse-fail!)))))))

;; ---------------------------------------------------------------- whole files

(defn- split-physical-lines [^String source]
  (let [n (.length source)]
    (loop [start 0 acc (transient [])]
      (let [i (.indexOf source (int \newline) (int start))]
        (if (neg? i)
          (persistent! (conj! acc (subs source start n)))
          (recur (inc i) (conj! acc (subs source start i))))))))

(defn lex-file
  "Lexes a whole build file: returns a vector of `{:line n :tokens [...]}`, one
  per non-empty logical line.  Throws a line-tagged parse error (see
  `buildsys.errors/with-line`) for the earliest lexical error."
  [^String source]
  (let [lines (split-physical-lines source)]
    (loop [idx 0 start nil parts [] depth 0 out []]
      (if (>= idx (count lines))
        (if (seq parts)
          (throw (e/with-line (ex-info "parse error" {::e/parse true}) start))
          out)
        (let [ln (inc idx)
              start (or start ln)
              [text depth'] (try (scan-line (nth lines idx) depth)
                                 (catch clojure.lang.ExceptionInfo ex
                                   (if (e/parse-error? ex) (throw (e/with-line ex start)) (throw ex))))
              parts (conj parts text)]
          (if (zero? depth')
            (let [logical (if (= 1 (count parts)) (first parts) (str/join " " parts))
                  out (if (every? #(or (= % \space) (= % \tab)) logical)
                        out
                        (let [toks (try (tokenize logical)
                                        (catch clojure.lang.ExceptionInfo ex
                                          (if (e/parse-error? ex) (throw (e/with-line ex start)) (throw ex))))]
                          (conj out {:line start :tokens toks})))]
              (recur (inc idx) nil [] 0 out))
            (recur (inc idx) start parts (long depth') out)))))))

;; --------------------------------------------------------- string literals

(defn read-literal
  "Parses the raw text of a string token into parts: a vector of byte strings
  (literal text) and `{:tokens [...]}` maps (interpolation bodies, already
  tokenised).  Throws a parse error for a bad escape, a lone `}` or an empty
  interpolation."
  [^String raw]
  (let [n (.length raw)]
    (if (= \' (.charAt raw 0))
      [(.replace (subs raw 1 (dec n)) "''" "'")]
      (loop [i 1 sb (StringBuilder.) parts []]
        (if (>= i (dec n))
          (if (zero? (.length sb)) parts (conj parts (str sb)))
          (let [c (.charAt raw i)]
            (cond
              (= c \\)
              (let [d (.charAt raw (inc i))
                    r (case d \\ \\ \" \" \n \newline \t \tab \r \return \0 (char 0) nil)]
                (when-not r (e/parse-fail!))
                (recur (+ i 2) (.append sb (char r)) parts))

              (= c \{)
              (if (= \{ (.charAt raw (inc i)))
                (recur (+ i 2) (.append sb \{) parts)
                (let [end (skip-interp raw (inc i))
                      toks (tokenize (subs raw (inc i) (dec end)))]
                  (when (empty? toks) (e/parse-fail!))
                  (recur end (StringBuilder.)
                         (cond-> parts
                           (pos? (.length sb)) (conj (str sb))
                           true (conj {:tokens toks})))))

              (= c \})
              (if (= \} (.charAt raw (inc i)))
                (recur (+ i 2) (.append sb \}) parts)
                (e/parse-fail!))

              :else (recur (inc i) (.append sb c) parts))))))))
