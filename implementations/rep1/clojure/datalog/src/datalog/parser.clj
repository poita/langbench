(ns datalog.parser
  "Text -> program data (see `datalog.syntax` for the data model).

  A hand-written lexer feeds a recursive-descent parser; the whole input is
  read in a single pass. Malformed input throws an `ex-info` whose data has
  `:type :datalog/parse-error`.")

(defn- parse-error [msg data]
  (throw (ex-info (str "parse error: " msg) (assoc data :type :datalog/parse-error))))

;; ---------------------------------------------------------------------------
;; Lexer. A token is `[kind value]`; kind is one of
;; :ident :var :anon :int :not :punct.

(defn- ident-char? [c]
  (or (<= (int \a) (int c) (int \z))
      (<= (int \A) (int c) (int \Z))
      (<= (int \0) (int c) (int \9))
      (= c \_)))

(defn- digit? [c]
  (<= (int \0) (int c) (int \9)))

(defn- lower? [c]
  (<= (int \a) (int c) (int \z)))

(defn- upper? [c]
  (<= (int \A) (int c) (int \Z)))

(defn- skip-ws
  "Index of the first character at or after `i` that is neither whitespace
  nor part of a comment."
  ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [i i]
      (if (>= i n)
        i
        (let [c (.charAt s i)]
          (cond
            (or (= c \space) (= c \tab) (= c \return) (= c \newline)) (recur (inc i))
            (= c \%) (let [j (.indexOf s "\n" (int i))]
                       (if (neg? j) n (recur (long j))))
            :else i))))))

(defn- scan-while ^long [^String s ^long i pred]
  (let [n (.length s)]
    (loop [j i]
      (if (and (< j n) (pred (.charAt s j))) (recur (inc j)) j))))

(defn tokenize
  "Splits `text` into a vector of tokens."
  [^String text]
  (let [n (.length text)]
    (loop [i (skip-ws text 0) out (transient [])]
      (if (>= i n)
        (persistent! out)
        (let [c (.charAt text i)
              nxt (if (< (inc i) n) (.charAt text (inc i)) (char 0))
              p (cond
                  (and (= c \:) (= nxt \-)) ":-"
                  (and (= c \?) (= nxt \-)) "?-"
                  (and (= c \<) (= nxt \=)) "<="
                  (and (= c \>) (= nxt \=)) ">="
                  (and (= c \!) (= nxt \=)) "!="
                  (contains? #{\( \) \, \. \< \> \=} c) (str c))]
          (cond
            p
            (recur (skip-ws text (+ i (.length ^String p))) (conj! out [:punct p]))

            (lower? c)
            (let [j (scan-while text i ident-char?)
                  w (subs text i j)]
              (recur (skip-ws text j) (conj! out (if (= w "not") [:not w] [:ident w]))))

            (upper? c)
            (let [j (scan-while text i ident-char?)]
              (recur (skip-ws text j) (conj! out [:var (subs text i j)])))

            (= c \_)
            (let [j (scan-while text i ident-char?)]
              (if (= j (inc i))
                (recur (skip-ws text j) (conj! out [:anon "_"]))
                (parse-error "identifier may not start with _" {:pos i})))

            (or (digit? c) (and (= c \-) (digit? nxt)))
            (let [j (scan-while text (inc i) digit?)]
              (recur (skip-ws text j) (conj! out [:int (Long/parseLong (subs text i j))])))

            :else (parse-error (str "unexpected character " (pr-str c)) {:pos i})))))))

;; ---------------------------------------------------------------------------
;; Parser. State is a token vector plus a position held in a volatile.

(defn- peek-tok [toks pos] (get toks @pos))

(defn- next-tok! [toks pos]
  (let [t (get toks @pos)]
    (when-not t (parse-error "unexpected end of input" {}))
    (vswap! pos inc)
    t))

(defn- punct? [t p] (and t (= (first t) :punct) (= (second t) p)))

(defn- expect! [toks pos p]
  (let [t (next-tok! toks pos)]
    (when-not (punct? t p)
      (parse-error (str "expected " p " but found " (pr-str (second t))) {:token t}))))

(defn- parse-term! [toks pos]
  (let [[kind v :as t] (next-tok! toks pos)]
    (case kind
      :int v
      :ident (keyword v)
      :var (symbol v)
      :anon '_
      (parse-error (str "expected a term but found " (pr-str v)) {:token t}))))

(defn- parse-atom-after-name!
  "Parses `( term, ... )` for the predicate `name` whose token was consumed."
  [toks pos name]
  (expect! toks pos "(")
  (loop [args [(parse-term! toks pos)]]
    (if (punct? (peek-tok toks pos) ",")
      (do (vswap! pos inc)
          (recur (conj args (parse-term! toks pos))))
      (do (expect! toks pos ")")
          {:pred name :args args}))))

(defn- parse-atom! [toks pos]
  (let [[kind v :as t] (next-tok! toks pos)]
    (when-not (= kind :ident)
      (parse-error (str "expected a predicate name but found " (pr-str v)) {:token t}))
    (parse-atom-after-name! toks pos v)))

(def ^:private cmp-ops #{"<" "<=" ">" ">=" "=" "!="})

(defn- parse-literal! [toks pos]
  (let [[kind v] (peek-tok toks pos)]
    (cond
      (= kind :not)
      (do (vswap! pos inc)
          {:op :neg :atom (parse-atom! toks pos)})

      (and (= kind :ident) (punct? (get toks (inc @pos)) "("))
      {:op :pos :atom (parse-atom! toks pos)}

      :else
      (let [l (parse-term! toks pos)
            [k op :as t] (next-tok! toks pos)]
        (when-not (and (= k :punct) (cmp-ops op))
          (parse-error (str "expected a comparison operator but found " (pr-str op)) {:token t}))
        {:op :cmp :cmp (keyword op) :left l :right (parse-term! toks pos)}))))

(defn- parse-clause!
  "Parses one clause; returns `[:rule rule]` or `[:query atom]`."
  [toks pos]
  (if (punct? (peek-tok toks pos) "?-")
    (do (vswap! pos inc)
        (let [a (parse-atom! toks pos)]
          (expect! toks pos ".")
          [:query a]))
    (let [head (parse-atom! toks pos)
          t (next-tok! toks pos)]
      (cond
        (punct? t ".") [:rule {:head head :body []}]
        (punct? t ":-")
        (loop [body [(parse-literal! toks pos)]]
          (let [t (next-tok! toks pos)]
            (cond
              (punct? t ",") (recur (conj body (parse-literal! toks pos)))
              (punct? t ".") [:rule {:head head :body body}]
              :else (parse-error (str "expected , or . but found " (pr-str (second t)))
                                 {:token t}))))
        :else (parse-error (str "expected . or :- but found " (pr-str (second t)))
                           {:token t})))))

(defn parse-program
  "Parses the text of a Datalog program into `{:rules [...] :queries [...]}`
  (facts are rules with an empty body). Both vectors keep source order."
  [text]
  (let [toks (tokenize text)
        pos (volatile! 0)]
    (loop [rules (transient []) queries (transient [])]
      (if (< @pos (count toks))
        (let [[kind x] (parse-clause! toks pos)]
          (if (= kind :rule)
            (recur (conj! rules x) queries)
            (recur rules (conj! queries x))))
        {:rules (persistent! rules) :queries (persistent! queries)}))))

(defn parse-atom
  "Parses a single atom such as `\"path(1, X)\"` (no trailing `.`); handy for
  ad-hoc queries."
  [text]
  (let [toks (tokenize text)
        pos (volatile! 0)
        a (parse-atom! toks pos)]
    (when (< @pos (count toks))
      (parse-error "trailing input after atom" {}))
    a))
