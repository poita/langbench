(ns sitegen.template.lexer
  "Splits template source into literal text and tags, applies whitespace
  control, and tokenizes the inside of `{{ }}` and `{% %}` tags.

  `tokenize` returns a vector of items:

  * `[:text s]`
  * `[:print tokens]`  for `{{ ... }}`
  * `[:stmt tokens]`   for `{% ... %}`

  Comments produce nothing.  A token is `[:name s]`, `[:int n]`, `[:float d]`,
  `[:string s]` or `[:op s]`."
  (:require [sitegen.template.value :as v]))

(set! *warn-on-reflection* true)

(defn- syntax-error! [msg] (v/error! :syntax msg))

(defn- ws? [c] (case c (\space \tab \newline \return \formfeed \u000B) true false))

(defn- name-start? [c] (or (<= (int \a) (int c) (int \z)) (<= (int \A) (int c) (int \Z)) (= c \_)))
(defn- digit? [c] (<= (int \0) (int c) (int \9)))
(defn- name-char? [c] (or (name-start? c) (digit? c)))

(def ^:private operators
  ["**" "//" "==" "!=" "<=" ">=" "~" "+" "-" "*" "/" "%" "<" ">" "(" ")" "[" "]" "," "|" "." "="])

(defn- lex-string
  "Lexes the string literal opening at `i`.  Returns [string next-index]."
  [^String s ^long i]
  (let [q (.charAt s i)
        n (.length s)
        sb (StringBuilder.)]
    (loop [j (inc i)]
      (when (>= j n) (syntax-error! "unterminated string"))
      (let [c (.charAt s j)]
        (cond
          (= c q) [(.toString sb) (inc j)]
          (= c \\)
          (do (when (>= (inc j) n) (syntax-error! "unterminated string"))
              (let [e (.charAt s (inc j))]
                (case e
                  \\ (.append sb \\)
                  \" (.append sb \")
                  \' (.append sb \')
                  \n (.append sb \newline)
                  \t (.append sb \tab)
                  (syntax-error! "bad string escape"))
                (recur (+ j 2))))
          :else (do (.append sb c) (recur (inc j))))))))

(defn- lex-number [^String s ^long i]
  (let [n (.length s)
        e (loop [j i] (if (and (< j n) (digit? (.charAt s j))) (recur (inc j)) j))]
    (if (and (< (inc e) n) (= (.charAt s e) \.) (digit? (.charAt s (inc e))))
      (let [f (loop [j (inc e)] (if (and (< j n) (digit? (.charAt s j))) (recur (inc j)) j))]
        [[:float (Double/parseDouble (.substring s (int i) (int f)))] f])
      [[:int (try (Long/parseLong (.substring s (int i) (int e)))
                  (catch NumberFormatException _ (syntax-error! "integer literal too large")))]
       e])))

(defn- lex-tag
  "Tokenizes the content of a `{{` or `{%` tag starting at `start` (just after
  the opener and its optional `-`).  `closer` is \"}}\" or \"%}\".  Returns
  [tokens index-after-closer trim-after?]."
  [^String s ^long start ^String closer]
  (let [n (.length s)
        dash-closer (str "-" closer)]
    (loop [i start tokens (transient [])]
      (let [i (loop [i i] (if (and (< i n) (ws? (.charAt s i))) (recur (inc i)) i))]
        (when (>= i n) (syntax-error! "unclosed tag"))
        (let [c (.charAt s i)]
          (cond
            (.startsWith s dash-closer (int i)) [(persistent! tokens) (+ i 3) true]
            (.startsWith s closer (int i)) [(persistent! tokens) (+ i 2) false]
            (name-start? c) (let [e (long (loop [j i] (if (and (< j n) (name-char? (.charAt s j))) (recur (inc j)) j)))]
                              (recur e (conj! tokens [:name (.substring s (int i) (int e))])))
            (digit? c) (let [[tok e] (lex-number s i)] (recur (long e) (conj! tokens tok)))
            (or (= c \") (= c \')) (let [[str e] (lex-string s i)] (recur (long e) (conj! tokens [:string str])))
            :else (if-let [op (some #(when (.startsWith s ^String % (int i)) %) operators)]
                    (recur (long (+ i (count ^String op))) (conj! tokens [:op op]))
                    (syntax-error! (str "unexpected character " c)))))))))

(defn- trim-end ^String [^String s]
  (loop [e (.length s)]
    (if (and (pos? e) (ws? (.charAt s (dec e)))) (recur (dec e)) (.substring s 0 e))))

(defn- trim-start ^String [^String s]
  (let [n (.length s)]
    (loop [b 0] (if (and (< b n) (ws? (.charAt s b))) (recur (inc b)) (.substring s b)))))

(defn- next-tag
  "Index of the first `{{`, `{%` or `{#` at or after `i`, or -1."
  ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [j i]
      (let [k (.indexOf s (int \{) (int j))]
        (cond
          (neg? k) -1
          (and (< (inc k) n) (case (.charAt s (inc k)) (\{ \% \#) true false)) k
          :else (recur (inc k)))))))

(defn tokenize
  "Lexes the template source `s` into a vector of items (see the namespace
  docstring).  Throws a `syntax` error on malformed input."
  [^String s]
  (let [n (.length s)]
    (loop [pos 0 items (transient []) trim-next? false]
      (let [tag (next-tag s pos)
            text-end (if (neg? tag) n tag)
            raw (.substring s (int pos) (int text-end))
            raw (if trim-next? (trim-start raw) raw)]
        (if (neg? tag)
          (persistent! (if (pos? (.length raw)) (conj! items [:text raw]) items))
          (let [kind (.charAt s (inc tag))
                dash? (and (< (+ tag 2) n) (= (.charAt s (+ tag 2)) \-))
                raw (if dash? (trim-end raw) raw)
                items (if (pos? (.length raw)) (conj! items [:text raw]) items)
                body (+ tag 2 (if dash? 1 0))]
            (if (= kind \#)
              (let [e (.indexOf s "#}" (int (+ tag 2)))]
                (when (neg? e) (syntax-error! "unclosed comment"))
                (recur (long (+ e 2)) items (and (> e (+ tag 2)) (= (.charAt s (dec e)) \-))))
              (let [[tokens after trim?] (lex-tag s body (if (= kind \{) "}}" "%}"))]
                (recur (long after)
                       (conj! items [(if (= kind \{) :print :stmt) tokens])
                       trim?)))))))))
