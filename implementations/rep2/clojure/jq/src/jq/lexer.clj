(ns jq.lexer
  "Tokenizer for filter source text.

  A token is a vector `[type value]`:

  | type     | value                                           |
  |----------|-------------------------------------------------|
  | `:num`   | double                                          |
  | `:str`   | decoded string                                  |
  | `:ident` | identifier or keyword text                      |
  | `:var`   | variable name (without `$`)                     |
  | `:field` | field name from `.name` or `.\"name\"`            |
  | `:dot`   | `nil` (a lone `.`)                              |
  | `:punct` | operator / punctuation text, e.g. `\"|\"`, `\"==\"` |")

(set! *warn-on-reflection* true)

(defn- lex-error [^String src i msg]
  (throw (ex-info (str "jq syntax error at offset " i ": " msg)
                  {:type ::syntax-error :offset i})))

(defn- ident-start? [c]
  (let [c (int c)] (or (<= 65 c 90) (<= 97 c 122) (== c 95))))

(defn- ident-char? [c]
  (or (ident-start? c) (<= 48 (int c) 57)))

(defn- digit? [c] (<= 48 (int c) 57))

(defn- scan-ident ^long [^String src ^long i]
  (loop [j i] (if (and (< j (.length src)) (ident-char? (.charAt src j))) (recur (inc j)) j)))

(defn- scan-string
  "Scans the string literal opening at `i`; returns [decoded next-index]."
  [^String src ^long i]
  (let [n (.length src) sb (StringBuilder.)]
    (loop [j (inc i)]
      (when (>= j n) (lex-error src i "unterminated string"))
      (let [c (.charAt src j)]
        (cond
          (= c \") [(str sb) (inc j)]
          (= c \\)
          (do (when (>= (inc j) n) (lex-error src j "bad escape"))
              (let [e (.charAt src (inc j))]
                (case e
                  \" (do (.append sb \") (recur (+ j 2)))
                  \\ (do (.append sb \\) (recur (+ j 2)))
                  \/ (do (.append sb \/) (recur (+ j 2)))
                  \b (do (.append sb \backspace) (recur (+ j 2)))
                  \f (do (.append sb \formfeed) (recur (+ j 2)))
                  \n (do (.append sb \newline) (recur (+ j 2)))
                  \r (do (.append sb \return) (recur (+ j 2)))
                  \t (do (.append sb \tab) (recur (+ j 2)))
                  \u (do (when (> (+ j 6) n) (lex-error src j "bad \\u escape"))
                         (.append sb (char (Integer/parseInt (.substring src (+ j 2) (+ j 6)) 16)))
                         (recur (+ j 6)))
                  (lex-error src j "bad escape"))))
          :else (do (.append sb c) (recur (inc j))))))))

(def ^:private two-char-ops #{"==" "!=" "<=" ">="})
(def ^:private one-char-ops (set "|,+-*/%<>()[]{}:;?"))

(defn tokenize
  "Splits the filter text `src` into a vector of tokens."
  [^String src]
  (let [n (.length src)]
    (loop [i 0 out (transient [])]
      (if (>= i n)
        (persistent! out)
        (let [c (.charAt src i)]
          (cond
            (or (= c \space) (= c \tab) (= c \newline) (= c \return)) (recur (inc i) out)

            (= c \.)
            (cond
              (and (< (inc i) n) (ident-start? (.charAt src (inc i))))
              (let [j (scan-ident src (inc i))]
                (recur (long j) (conj! out [:field (.substring src (inc i) j)])))
              (and (< (inc i) n) (= (.charAt src (inc i)) \"))
              (let [[s j] (scan-string src (inc i))]
                (recur (long j) (conj! out [:field s])))
              :else (recur (inc i) (conj! out [:dot nil])))

            (= c \")
            (let [[s j] (scan-string src i)] (recur (long j) (conj! out [:str s])))

            (= c \$)
            (if (and (< (inc i) n) (ident-start? (.charAt src (inc i))))
              (let [j (scan-ident src (inc i))]
                (recur (long j) (conj! out [:var (.substring src (inc i) j)])))
              (lex-error src i "expected variable name"))

            (digit? c)
            (let [j (loop [j i] (if (and (< j n) (digit? (.charAt src j))) (recur (inc j)) j))
                  j (if (and (< (inc j) n) (= (.charAt src j) \.) (digit? (.charAt src (inc j))))
                      (loop [j (inc j)] (if (and (< j n) (digit? (.charAt src j))) (recur (inc j)) j))
                      j)]
              (recur (long j) (conj! out [:num (Double/parseDouble (.substring src i j))])))

            (ident-start? c)
            (let [j (scan-ident src i)]
              (recur (long j) (conj! out [:ident (.substring src i j)])))

            (and (< (inc i) n) (two-char-ops (.substring src i (+ i 2))))
            (recur (+ i 2) (conj! out [:punct (.substring src i (+ i 2))]))

            (one-char-ops c) (recur (inc i) (conj! out [:punct (str c)]))

            :else (lex-error src i (str "unexpected character " (pr-str c)))))))))
