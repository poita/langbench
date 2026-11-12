(ns kvstore.lexer
  "Turns one command line into tokens (spec section 6.1).

  A token is a vector `[kind value]`:

  | kind      | value                                                    |
  |-----------|----------------------------------------------------------|
  | `:word`   | the word's text                                          |
  | `:int`    | the digit text, including any leading `-`                |
  | `:string` | the decoded text as a Java string (UTF-16 code units; a  |
  |           | `\\uXXXX` escape may leave an unpaired surrogate, which  |
  |           | the parser reports as `bad-utf8` when it resolves it)    |
  | `:punct`  | one of `{ } [ ] ( ) , : .` as a string                   |
  | `:op`     | one of `== != <= >= < >`                                 |

  Lexical problems throw `ex-info` with `:kind :syntax`.")

(set! *warn-on-reflection* true)

(defn- syntax-error []
  (throw (ex-info "syntax error" {:kind :syntax})))

(defn- word-start? [^Character c]
  (let [c (char c)]
    (or (and (>= (int c) (int \a)) (<= (int c) (int \z)))
        (and (>= (int c) (int \A)) (<= (int c) (int \Z)))
        (= c \_))))

(defn- digit? [c] (and (>= (int c) (int \0)) (<= (int c) (int \9))))

(defn- word-char? [c] (or (word-start? c) (digit? c)))

(defn- hex-val ^long [c]
  (let [d (Character/digit (char c) 16)]
    (when (or (neg? d) (> (int c) 127)) (syntax-error))
    d))

(defn- lex-string
  "Lex a string literal starting at the opening quote at `i`; returns
  `[token next-index]`."
  [^String s ^long i]
  (let [n (.length s)
        sb (StringBuilder.)]
    (loop [j (inc i)]
      (when (>= j n) (syntax-error))
      (let [c (.charAt s j)]
        (cond
          (= c \") [[:string (.toString sb)] (inc j)]
          (< (int c) 0x20) (syntax-error)
          (= c \\)
          (do
            (when (>= (inc j) n) (syntax-error))
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
                \u (do
                     (when (> (+ j 6) n) (syntax-error))
                     (let [code (+ (* 4096 (hex-val (.charAt s (+ j 2))))
                                   (* 256 (hex-val (.charAt s (+ j 3))))
                                   (* 16 (hex-val (.charAt s (+ j 4))))
                                   (hex-val (.charAt s (+ j 5))))]
                       (.append sb (char code))
                       (recur (+ j 6))))
                (syntax-error))))
          :else (do (.append sb c) (recur (inc j))))))))

(defn- lex-int [^String s ^long i]
  (let [n (.length s)
        neg? (= (.charAt s i) \-)
        d0 (if neg? (inc i) i)]
    (when (or (>= d0 n) (not (digit? (.charAt s d0)))) (syntax-error))
    (let [end (loop [j d0] (if (and (< j n) (digit? (.charAt s j))) (recur (inc j)) j))
          digits (subs s d0 end)]
      (when (and (> (count digits) 1) (= (first digits) \0)) (syntax-error))
      (when (and neg? (= digits "0")) (syntax-error))
      [[:int (subs s i end)] end])))

(defn tokenize
  "Tokenise `line` (a string).  Returns a vector of tokens."
  [^String line]
  (let [n (.length line)]
    (loop [i 0 toks (transient [])]
      (if (>= i n)
        (persistent! toks)
        (let [c (.charAt line i)]
          (cond
            (or (= c \space) (= c \tab)) (recur (inc i) toks)

            (word-start? c)
            (let [end (loop [j (inc i)] (if (and (< j n) (word-char? (.charAt line j))) (recur (inc j)) j))]
              (recur (long end) (conj! toks [:word (subs line i end)])))

            (or (digit? c) (= c \-))
            (let [[tok end] (lex-int line i)] (recur (long end) (conj! toks tok)))

            (= c \")
            (let [[tok end] (lex-string line i)] (recur (long end) (conj! toks tok)))

            (#{\{ \} \[ \] \( \) \, \: \.} c)
            (recur (inc i) (conj! toks [:punct (str c)]))

            (or (= c \=) (= c \!) (= c \<) (= c \>))
            (let [nxt (when (< (inc i) n) (.charAt line (inc i)))]
              (cond
                (= nxt \=) (recur (+ i 2) (conj! toks [:op (str c "=")]))
                (or (= c \<) (= c \>)) (recur (inc i) (conj! toks [:op (str c)]))
                :else (syntax-error)))

            :else (syntax-error)))))))
