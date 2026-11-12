(ns template.lexer
  "Splits a template body into text and tags and tokenizes tag contents.

  [[lex]] returns a vector of items:

  * `[:text string]`          literal text (whitespace control already applied)
  * `[:print tokens]`         a `{{ }}` tag
  * `[:stmt tokens]`          a `{% %}` tag

  Comments are dropped. A token is `[:name s]`, `[:int n]`, `[:float d]`,
  `[:str s]` or `[:op s]`."
  (:require [template.errors :as err]
            [template.values :refer [whitespace-char?]]))

(set! *warn-on-reflection* true)

(defn- syntax! [msg] (err/fail :syntax msg))

(defn- name-start? [c] (or (and (<= (int \a) (int c) (int \z)) true)
                           (and (<= (int \A) (int c) (int \Z)) true)
                           (== (int c) (int \_))))
(defn- digit? [c] (<= (int \0) (int c) (int \9)))
(defn- name-char? [c] (or (name-start? c) (digit? c)))

(def ^:private two-char-ops #{"**" "//" "==" "!=" "<=" ">="})
(def ^:private one-char-ops (set (map str "~+-*/%<>()[],|.=")))

(defn- lex-string
  "Lex a string literal whose opening quote is at `i`; returns [token next-i]."
  [^String s ^long i]
  (let [q (.charAt s i) n (.length s) sb (StringBuilder.)]
    (loop [j (inc i)]
      (when (>= j n) (syntax! "unterminated string literal"))
      (let [c (.charAt s j)]
        (cond
          (= c q) [[:str (.toString sb)] (inc j)]
          (= c \\)
          (let [e (when (< (inc j) n) (.charAt s (inc j)))]
            (case e
              \\ (.append sb \\)
              \" (.append sb \")
              \' (.append sb \')
              \n (.append sb \newline)
              \t (.append sb \tab)
              (syntax! "bad escape in string literal"))
            (recur (+ j 2)))
          :else (do (.append sb c) (recur (inc j))))))))

(defn- lex-number [^String s ^long i]
  (let [n (.length s)
        j (loop [j i] (if (and (< j n) (digit? (.charAt s j))) (recur (inc j)) j))]
    (if (and (< (inc j) n) (= (.charAt s j) \.) (digit? (.charAt s (inc j))))
      (let [k (loop [k (inc j)] (if (and (< k n) (digit? (.charAt s k))) (recur (inc k)) k))]
        [[:float (Double/parseDouble (.substring s i k))] k])
      [[:int (try (Long/parseLong (.substring s i j))
                  (catch NumberFormatException _ (syntax! "integer literal too large")))]
       j])))

(defn- lex-tag
  "Tokenize a tag's content starting at `i` until its closer. `closer` is `\\}`
  for `{{` and `\\%` for `{%`. Returns [tokens next-i strip-following?]."
  [^String s ^long i closer]
  (let [n (.length s)
        closer (char closer)]
    (loop [i i toks (transient [])]
      (let [i (long (loop [i i] (if (and (< i n) (whitespace-char? (.charAt s i))) (recur (inc i)) i)))]
        (when (>= i n) (syntax! "unclosed tag"))
        (let [c (.charAt s i)]
          (cond
            ;; closer, checked before operators
            (and (= c closer) (< (inc i) n) (= (.charAt s (inc i)) \}))
            [(persistent! toks) (+ i 2) false]

            (and (= c \-) (< (+ i 2) n) (= (.charAt s (inc i)) closer) (= (.charAt s (+ i 2)) \}))
            [(persistent! toks) (+ i 3) true]

            (name-start? c)
            (let [j (long (loop [j (inc i)] (if (and (< j n) (name-char? (.charAt s j))) (recur (inc j)) j)))]
              (recur j (conj! toks [:name (.substring s i j)])))

            (digit? c)
            (let [[tok j] (lex-number s i)] (recur (long j) (conj! toks tok)))

            (or (= c \") (= c \'))
            (let [[tok j] (lex-string s i)] (recur (long j) (conj! toks tok)))

            (and (< (inc i) n) (contains? two-char-ops (.substring s i (+ i 2))))
            (recur (+ i 2) (conj! toks [:op (.substring s i (+ i 2))]))

            (contains? one-char-ops (String/valueOf c))
            (recur (inc i) (conj! toks [:op (String/valueOf c)]))

            :else (syntax! (str "unexpected character in tag: " c))))))))

(defn- strip-leading ^String [^String s]
  (let [n (.length s)
        a (loop [i 0] (if (and (< i n) (whitespace-char? (.charAt s i))) (recur (inc i)) i))]
    (if (zero? a) s (.substring s a))))

(defn- strip-trailing ^String [^String s]
  (let [b (loop [j (.length s)] (if (and (pos? j) (whitespace-char? (.charAt s (dec j)))) (recur (dec j)) j))]
    (if (== b (.length s)) s (.substring s 0 b))))

(defn- find-opener
  "Index of the next `{{`, `{%` or `{#` at or after `from`, or -1."
  ^long [^String s ^long from]
  (let [n (.length s)]
    (loop [j from]
      (let [k (.indexOf s "{" (int j))]
        (cond
          (or (neg? k) (>= (inc k) n)) -1
          (let [c (.charAt s (inc k))] (or (= c \{) (= c \%) (= c \#))) k
          :else (recur (inc k)))))))

(defn lex
  "Split template source `src` into items (see the namespace docs)."
  [^String src]
  (let [n (.length src)]
    (loop [pos 0 strip-next? false items (transient [])]
      (let [j (find-opener src pos)]
        (if (neg? j)
          (let [text (.substring src pos n)
                text (if strip-next? (strip-leading text) text)]
            (persistent! (if (.isEmpty text) items (conj! items [:text text]))))
          (let [kind (.charAt src (inc j))
                dash? (and (< (+ j 2) n) (= (.charAt src (+ j 2)) \-))
                k (if dash? (+ j 3) (+ j 2))
                text (.substring src pos j)
                text (if strip-next? (strip-leading text) text)
                text (if dash? (strip-trailing text) text)
                items (if (.isEmpty text) items (conj! items [:text text]))]
            (if (= kind \#)
              (let [e (.indexOf src "#}" (int k))]
                (when (neg? e) (syntax! "unclosed comment"))
                (recur (+ e 2) (and (> e k) (= (.charAt src (dec e)) \-)) items))
              (let [[toks next-i strip?] (lex-tag src k (if (= kind \{) \} \%))]
                (recur (long next-i) strip?
                       (conj! items [(if (= kind \{) :print :stmt) toks]))))))))))
