(ns jq.lexer
  "Turns filter source text into a vector of tokens.

  A token is a two-element vector `[kind value]`:

  | kind     | value                                   |
  |----------|-----------------------------------------|
  | `:num`   | the number as a double                  |
  | `:str`   | the decoded string literal              |
  | `:id`    | an identifier or keyword                |
  | `:var`   | the name of a `$name` variable          |
  | `:field` | the name in `.name`                     |
  | `:op`    | punctuation / operator text             |"
  (:require [jq.value :as v]))

(defn- fail [^String s i msg]
  (throw (ex-info (str "filter syntax error at offset " i ": " msg)
                  {:type :jq/parse-error :offset i})))

(defn- ident-start? [c] (or (Character/isLetter (char c)) (== (int c) 95)))
(defn- ident-char? [c] (or (ident-start? c) (Character/isDigit (char c))))
(defn- digit? [c] (and (>= (int c) 48) (<= (int c) 57)))

(defn- scan-while ^long [^String s ^long i pred]
  (let [n (.length s)]
    (loop [j i] (if (and (< j n) (pred (.charAt s j))) (recur (inc j)) j))))

(defn- lex-string
  "Lexes a string literal starting at the opening quote at `i`. Returns
  `[string next-index]`."
  [^String s ^long i]
  (let [n (.length s) sb (StringBuilder.)]
    (loop [j (inc i)]
      (when (>= j n) (fail s i "unterminated string"))
      (let [c (.charAt s j)]
        (cond
          (v/ceq c \") [(.toString sb) (inc j)]
          (v/ceq c \\)
          (do (when (>= (inc j) n) (fail s j "bad escape"))
              (let [e (.charAt s (inc j))]
                (case e
                  \" (do (.append sb \") (recur (+ j 2)))
                  \\ (do (.append sb \\) (recur (+ j 2)))
                  \/ (do (.append sb \/) (recur (+ j 2)))
                  \b (do (.append sb \backspace) (recur (+ j 2)))
                  \f (do (.append sb \formfeed) (recur (+ j 2)))
                  \n (do (.append sb \newline) (recur (+ j 2)))
                  \r (do (.append sb \return) (recur (+ j 2)))
                  \t (do (.append sb \tab) (recur (+ j 2)))
                  \u (do (when (> (+ j 6) n) (fail s j "bad \\u escape"))
                         (.append sb (char (Long/parseLong (.substring s (+ j 2) (+ j 6)) 16)))
                         (recur (+ j 6)))
                  (fail s j "bad escape"))))
          :else (do (.append sb c) (recur (inc j))))))))

(defn tokenize
  "Returns the vector of tokens of the filter source `s`. Throws `ex-info`
  with `{:type :jq/parse-error}` on a character that starts no token."
  [^String s]
  (let [n (.length s)]
    (loop [i 0 out (transient [])]
      (if (>= i n)
        (persistent! out)
        (let [c (.charAt s i)
              c2 (when (< (inc i) n) (.charAt s (inc i)))]
          (cond
            (or (v/ceq c \space) (v/ceq c \tab) (v/ceq c \newline) (v/ceq c \return))
            (recur (inc i) out)

            (digit? c)
            (let [j (scan-while s i digit?)
                  j (if (and (< (inc j) n) (v/ceq (.charAt s j) \.) (digit? (.charAt s (inc j))))
                      (scan-while s (inc j) digit?)
                      j)]
              (recur j (conj! out [:num (Double/parseDouble (.substring s i j))])))

            (v/ceq c \")
            (let [[str j] (lex-string s i)]
              (recur j (conj! out [:str str])))

            (ident-start? c)
            (let [j (scan-while s i ident-char?)]
              (recur j (conj! out [:id (.substring s i j)])))

            (and (v/ceq c \$) c2 (ident-start? c2))
            (let [j (scan-while s (inc i) ident-char?)]
              (recur j (conj! out [:var (.substring s (inc i) j)])))

            (and (v/ceq c \.) c2 (ident-start? c2))
            (let [j (scan-while s (inc i) ident-char?)]
              (recur j (conj! out [:field (.substring s (inc i) j)])))

            (and c2 (v/ceq c2 \=) (or (v/ceq c \=) (v/ceq c \!) (v/ceq c \<) (v/ceq c \>)))
            (recur (+ i 2) (conj! out [:op (.substring s i (+ i 2))]))

            (>= (.indexOf "|,:;()[]{}?+-*/%<>." (int c)) 0)
            (recur (inc i) (conj! out [:op (String/valueOf c)]))

            :else (fail s i (str "unexpected character " (pr-str c)))))))))
