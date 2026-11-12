(ns minisql.lexer
  "Tokenizer.  Turns a SQL script into a vector of statements, each a vector
  of tokens.

  A token is a two-element vector `[type value]`:

  | type           | value                                              |
  |----------------|----------------------------------------------------|
  | `:kw`          | reserved keyword as a lower-case Clojure keyword   |
  | `:id`          | identifier, lower-cased string                     |
  | `:int`         | the digits of an integer literal, as a string      |
  | `:str`         | string literal contents (quotes unescaped)         |
  | `:op`          | operator / punctuation as a string, e.g. `\"<=\"`  |
  | `:invalid`     | a character that is not part of the language       |
  | `:unterminated`| a string literal that is never closed (always last)|

  The statement separator `;` is not part of any statement's token vector.")

(def reserved
  "The reserved keywords of the dialect, as lower-case keywords."
  (into #{} (map keyword)
        (re-seq #"[a-z]+"
                "select from where and or not null is like as insert into values
                 delete update set create table integer text inner join on group
                 by having order asc desc limit offset left right full outer
                 cross natural")))

(defn- whitespace? [c]
  (case c
    (\space \tab \return \newline \formfeed \u000B) true
    false))

(defn- ident-start? [c]
  (or (and (>= (int c) (int \a)) (<= (int c) (int \z)))
      (and (>= (int c) (int \A)) (<= (int c) (int \Z)))
      (= c \_)))

(defn- digit? [c] (and (>= (int c) (int \0)) (<= (int c) (int \9))))

(defn- ident-part? [c] (or (ident-start? c) (digit? c)))

(defn- scan
  "Index of the first char at or after `i` that fails `pred` (or the length)."
  ^long [pred ^String s ^long i]
  (let [n (.length s)]
    (loop [j i]
      (if (and (< j n) (pred (.charAt s j))) (recur (inc j)) j))))

(def ^:private two-char-ops #{"<=" ">=" "!=" "<>" "=="})
(def ^:private one-char-ops #{\+ \- \* \/ \% \= \< \> \( \) \, \.})

(defn- lex-string
  "Lex a string literal whose opening quote is at `start`.  Returns
  `[token next-index]`; the token is `[:unterminated nil]` when unclosed."
  [^String s ^long start]
  (let [n (.length s)
        sb (StringBuilder.)]
    (loop [from (inc start)]
      (let [q (.indexOf s "'" (int from))]
        (cond
          (neg? q) [[:unterminated nil] n]
          (and (< (inc q) n) (= \' (.charAt s (inc q))))
          (do (.append sb s (int from) (int (inc q)))
              (recur (+ q 2)))
          :else (do (.append sb s (int from) (int q))
                    [[:str (str sb)] (inc q)]))))))

(defn tokenize
  "Tokenize the whole of `s`.  Returns a vector of tokens in which a `;` is
  the token `[:semi nil]`.  Lexing stops after an `:unterminated` token."
  [^String s]
  (let [n (.length s)]
    (loop [i 0, out (transient [])]
      (if (>= i n)
        (persistent! out)
        (let [c (.charAt s i)]
          (cond
            (whitespace? c) (recur (inc i) out)

            (and (= c \-) (< (inc i) n) (= \- (.charAt s (inc i))))
            (let [j (.indexOf s "\n" (int i))]
              (recur (if (neg? j) n j) out))

            (ident-start? c)
            (let [j (scan ident-part? s i)
                  word (.toLowerCase (subs s i j) java.util.Locale/ROOT)
                  kw (keyword word)]
              (recur j (conj! out (if (reserved kw) [:kw kw] [:id word]))))

            (digit? c)
            (let [j (scan digit? s i)]
              (recur j (conj! out [:int (subs s i j)])))

            (= c \')
            (let [[tok j] (lex-string s i)]
              (if (= :unterminated (first tok))
                (persistent! (conj! out tok))
                (recur (long j) (conj! out tok))))

            (= c \;) (recur (inc i) (conj! out [:semi nil]))

            :else
            (let [two (when (< (inc i) n) (subs s i (+ i 2)))]
              (cond
                (and two (two-char-ops two)) (recur (+ i 2) (conj! out [:op two]))
                (one-char-ops c) (recur (inc i) (conj! out [:op (str c)]))
                :else (recur (inc i) (conj! out [:invalid (str c)]))))))))))

(defn statements
  "Split the script `s` into statements: a vector of non-empty token vectors.
  Empty statements are dropped.  A final statement without `;` is kept."
  [s]
  (let [[stmts cur]
        (reduce (fn [[stmts cur] tok]
                  (if (= :semi (first tok))
                    [(if (seq cur) (conj stmts cur) stmts) []]
                    [stmts (conj cur tok)]))
                [[] []]
                (tokenize s))]
    (if (seq cur) (conj stmts cur) stmts)))
