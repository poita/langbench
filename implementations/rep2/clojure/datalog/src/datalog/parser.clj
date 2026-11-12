(ns datalog.parser
  "Tokeniser and recursive-descent parser for Datalog programs.

  [[parse-program]] turns program text into a vector of *clauses*.

  Terms are plain Clojure values:

  * integer constant    -> `Long`
  * identifier constant -> `String`
  * variable            -> `Symbol`.  Each anonymous variable `_` is renamed to
    a fresh symbol (`_1`, `_2`, ...) that cannot clash with a user variable.

  An *atom* is `{:pred \"name\" :args [term ...]}`.  A *literal* is either
  `{:kind :atom :negated? bool :pred .. :args ..}` or
  `{:kind :cmp :op :< | :<= | :> | :>= | := | :!= :left term :right term}`.

  A *clause* is one of

  * `{:type :rule  :head atom :body [literal ...]}` (a fact has an empty body)
  * `{:type :query :atom atom}`

  Malformed input throws `ex-info` with `{:type :parse-error :pos n}`.")

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Tokeniser

(defn- ident-char? [c]
  (let [c (long (int c))]
    (or (<= 97 c 122) (<= 65 c 90) (<= 48 c 57) (== c 95))))

(defn- digit? [c] (<= 48 (long (int c)) 57))

(defn- fail [msg pos]
  (throw (ex-info (str "parse error at offset " pos ": " msg)
                  {:type :parse-error :pos pos})))

(defn tokenize
  "Splits `text` into a vector of `[type value pos]` tokens.

  Types: `:ident`, `:var`, `:anon`, `:int`, `:not`, and `:punct` (the value
  names the punctuation, e.g. `:lparen`, `:neck`, `:<=`).  Comments and
  whitespace are dropped."
  [^String text]
  (let [n (.length text)
        out (java.util.ArrayList.)]
    (loop [i 0]
      (when (< i n)
        (let [c (.charAt text i)
              nxt (fn [k] (when (< (+ i k) n) (.charAt text (+ i k))))
              punct (fn [kw] (.add out [:punct kw i]))]
          (cond
            (or (= c \space) (= c \tab) (= c \return) (= c \newline))
            (recur (inc i))

            (= c \%)
            (recur (long (let [e (.indexOf text "\n" (int i))] (if (neg? e) n (inc e)))))

            (= c \() (do (punct :lparen) (recur (+ i 1)))
            (= c \)) (do (punct :rparen) (recur (+ i 1)))
            (= c \,) (do (punct :comma) (recur (+ i 1)))
            (= c \.) (do (punct :dot) (recur (+ i 1)))
            (= c \=) (do (punct :=) (recur (+ i 1)))
            (= c \!) (if (= (nxt 1) \=)
                       (do (punct :!=) (recur (+ i 2)))
                       (fail "unexpected '!'" i))
            (= c \<) (if (= (nxt 1) \=) (do (punct :<=) (recur (+ i 2))) (do (punct :<) (recur (+ i 1))))
            (= c \>) (if (= (nxt 1) \=) (do (punct :>=) (recur (+ i 2))) (do (punct :>) (recur (+ i 1))))
            (= c \:) (if (= (nxt 1) \-)
                       (do (punct :neck) (recur (+ i 2)))
                       (fail "expected ':-'" i))
            (= c \?) (if (= (nxt 1) \-)
                       (do (punct :query) (recur (+ i 2)))
                       (fail "expected '?-'" i))

            (or (digit? c) (and (= c \-) (some-> (nxt 1) digit?)))
            (let [s (if (= c \-) (inc i) i)
                  e (loop [j s] (if (and (< j n) (digit? (.charAt text j))) (recur (inc j)) j))]
              (.add out [:int (Long/parseLong (subs text i e)) i])
              (recur (long e)))

            (ident-char? c)
            (let [e (loop [j (inc i)] (if (and (< j n) (ident-char? (.charAt text j))) (recur (inc j)) j))
                  word (subs text i e)]
              (.add out
                    (cond
                      (= word "_") [:anon nil i]
                      (= word "not") [:not nil i]
                      (<= 65 (long (int c)) 90) [:var word i]
                      (<= 97 (long (int c)) 122) [:ident word i]
                      :else (fail (str "unexpected token " word) i)))
              (recur (long e)))

            :else (fail (str "unexpected character " (pr-str c)) i)))))
    (vec out)))

;; ---------------------------------------------------------------------------
;; Parser
;;
;; The parser threads a position through the token vector; each parse
;; function returns `[result next-pos]`.

(def ^:private cmp-ops #{:< :<= :> :>= := :!=})

(defn- peek-tok [toks ^long i]
  (nth toks i nil))

(defn- expect [toks ^long i punct what]
  (let [[t v pos] (peek-tok toks i)]
    (if (and (= t :punct) (= v punct))
      (inc i)
      (fail (str "expected " what) (or pos -1)))))

(defn- parse-term
  "Parses a term; `fresh` is a function returning a fresh anonymous variable."
  [toks ^long i fresh]
  (let [[t v pos] (peek-tok toks i)]
    (case t
      (:int :ident) [v (inc i)]
      :var [(symbol v) (inc i)]
      :anon [(fresh) (inc i)]
      (fail "expected a term" (or pos -1)))))

(defn- parse-atom-args [toks ^long i fresh]
  (loop [i (expect toks i :lparen "'('") args []]
    (let [[term i] (parse-term toks i fresh)
          args (conj args term)
          [t v pos] (peek-tok toks i)]
      (cond
        (and (= t :punct) (= v :comma)) (recur (inc i) args)
        (and (= t :punct) (= v :rparen)) [args (inc i)]
        :else (fail "expected ',' or ')'" (or pos -1))))))

(defn- parse-atom [toks ^long i fresh]
  (let [[t v pos] (peek-tok toks i)]
    (when-not (= t :ident) (fail "expected a predicate name" (or pos -1)))
    (let [[args i] (parse-atom-args toks (inc i) fresh)]
      [{:pred v :args args} i])))

(defn- parse-literal [toks ^long i fresh]
  (let [[t v] (peek-tok toks i)]
    (cond
      (= t :not)
      (let [[atom i] (parse-atom toks (inc i) fresh)]
        [(assoc atom :kind :atom :negated? true) i])

      ;; An identifier followed by "(" starts an atom; anything else is the
      ;; left-hand side of a comparison.
      (and (= t :ident)
           (let [[t2 v2] (peek-tok toks (inc i))] (and (= t2 :punct) (= v2 :lparen))))
      (let [[atom i] (parse-atom toks i fresh)]
        [(assoc atom :kind :atom :negated? false) i])

      :else
      (let [[left i] (parse-term toks i fresh)
            [t2 op pos] (peek-tok toks i)]
        (when-not (and (= t2 :punct) (cmp-ops op))
          (fail "expected a comparison operator" (or pos -1)))
        (let [[right i] (parse-term toks (inc i) fresh)]
          [{:kind :cmp :op op :left left :right right} i])))))

(defn- parse-clause [toks ^long i fresh]
  (let [[t v] (peek-tok toks i)]
    (if (and (= t :punct) (= v :query))
      (let [[atom i] (parse-atom toks (inc i) fresh)]
        [{:type :query :atom atom} (expect toks i :dot "'.'")])
      (let [[head i] (parse-atom toks i fresh)
            [t2 v2] (peek-tok toks i)]
        (if (and (= t2 :punct) (= v2 :neck))
          (loop [i (inc i) body []]
            (let [[lit i] (parse-literal toks i fresh)
                  body (conj body lit)
                  [t3 v3 pos] (peek-tok toks i)]
              (cond
                (and (= t3 :punct) (= v3 :comma)) (recur (inc i) body)
                (and (= t3 :punct) (= v3 :dot)) [{:type :rule :head head :body body} (inc i)]
                :else (fail "expected ',' or '.'" (or pos -1)))))
          [{:type :rule :head head :body []} (expect toks i :dot "'.' or ':-'")])))))

(defn parse-program
  "Parses the text of a whole program into a vector of clauses (see the
  namespace docstring for their shape)."
  [^String text]
  (let [toks (tokenize text)
        counter (volatile! 0)
        fresh #(symbol (str "_" (vswap! counter inc)))
        n (count toks)]
    (loop [i 0 clauses (transient [])]
      (if (< i n)
        (let [[clause i] (parse-clause toks i fresh)]
          (recur (long i) (conj! clauses clause)))
        (persistent! clauses)))))
