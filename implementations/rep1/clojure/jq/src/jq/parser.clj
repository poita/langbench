(ns jq.parser
  "Recursive-descent parser from filter text to a syntax tree.

  The tree is made of plain maps with an `:op` key:

  | `:op`      | other keys                                       |
  |------------|--------------------------------------------------|
  | `:identity`|                                                  |
  | `:literal` | `:v` (nil, boolean, double or string)            |
  | `:var`     | `:name`                                          |
  | `:paren`   | `:e`                                             |
  | `:neg`     | `:e`                                             |
  | `:pipe` `:comma` `:and` `:or` | `:l` `:r`                     |
  | `:binop`   | `:f` (one of `:+ :- :* :/ :% :== :!= :< :<= :> :>=`), `:l` `:r` |
  | `:array`   | `:e` (or nil for `[]`)                           |
  | `:object`  | `:entries` — vector of `[key-node value-node]`   |
  | `:if`      | `:cond` `:then` `:else` (else may be nil)        |
  | `:bind`    | `:src` `:name` `:body`                           |
  | `:reduce`  | `:src` `:name` `:init` `:update`                 |
  | `:index`   | `:term` `:idx` `:opt`                            |
  | `:iterate` | `:term` `:opt`                                   |
  | `:slice`   | `:term` `:from` `:to` `:opt` (bounds may be nil) |
  | `:try`     | `:e`                                             |
  | `:call`    | `:name` `:args`                                  |"
  (:require [jq.lexer :as lexer]))

(declare parse-pipe)

;; --- token stream helpers: state is {:toks [...] :pos (volatile! i)}

(defn- fail [st msg]
  (throw (ex-info (str "filter syntax error: " msg " (token " @(:pos st) ")")
                  {:type :jq/parse-error})))

(defn- peek-tok
  ([st] (peek-tok st 0))
  ([st k] (get (:toks st) (+ @(:pos st) k))))

(defn- advance! [st] (vswap! (:pos st) inc))

(defn- op? [tok s] (and tok (= :op (tok 0)) (= s (tok 1))))
(defn- id? [tok s] (and tok (= :id (tok 0)) (= s (tok 1))))

(defn- expect-op! [st s]
  (if (op? (peek-tok st) s) (advance! st) (fail st (str "expected '" s "'"))))

(defn- expect-id! [st s]
  (if (id? (peek-tok st) s) (advance! st) (fail st (str "expected '" s "'"))))

(defn- expect-var! [st]
  (let [t (peek-tok st)]
    (if (and t (= :var (t 0))) (do (advance! st) (t 1)) (fail st "expected $variable"))))

(defn- lit [v] {:op :literal :v v})

;; --- expressions, loosest to tightest

(declare parse-comma parse-or parse-and parse-cmp parse-add parse-mul parse-unary parse-postfix
         parse-primary)

(defn- left-assoc
  "Parses `operand {op operand}` for the operators in `ops`, left-associative,
  building nodes with `mk`."
  [st operand ops mk]
  (loop [l (operand st)]
    (let [t (peek-tok st)]
      (if (and t (= :op (t 0)) (ops (t 1)))
        (do (advance! st) (recur (mk (t 1) l (operand st))))
        l))))

(defn- parse-pipe [st]
  (let [l (parse-comma st)]
    (if (op? (peek-tok st) "|")
      (do (advance! st) {:op :pipe :l l :r (parse-pipe st)})
      l)))

(defn- parse-comma [st]
  (loop [l (parse-or st)]
    (if (op? (peek-tok st) ",")
      (do (advance! st) (recur {:op :comma :l l :r (parse-or st)}))
      l)))

(defn- parse-or [st]
  (loop [l (parse-and st)]
    (if (id? (peek-tok st) "or")
      (do (advance! st) (recur {:op :or :l l :r (parse-and st)}))
      l)))

(defn- parse-and [st]
  (loop [l (parse-cmp st)]
    (if (id? (peek-tok st) "and")
      (do (advance! st) (recur {:op :and :l l :r (parse-cmp st)}))
      l)))

(defn- parse-cmp [st]
  (let [l (parse-add st)
        t (peek-tok st)]
    (if (and t (= :op (t 0)) (#{"==" "!=" "<" "<=" ">" ">="} (t 1)))
      (do (advance! st)
          {:op :binop :f (keyword (t 1)) :l l :r (parse-add st)})
      l)))

(defn- binop [o l r] {:op :binop :f (keyword o) :l l :r r})

(defn- parse-add [st] (left-assoc st parse-mul #{"+" "-"} binop))
(defn- parse-mul [st] (left-assoc st parse-unary #{"*" "/" "%"} binop))

(defn- parse-unary [st]
  (if (op? (peek-tok st) "-")
    (do (advance! st) {:op :neg :e (parse-unary st)})
    (parse-postfix st true)))

;; --- postfix terms

(defn- make-opt
  "`?` after a path suffix makes that suffix tolerant; after anything else it
  is `try`."
  [node]
  (if (and (#{:index :iterate :slice} (:op node)) (not (:opt node)))
    (assoc node :opt true)
    {:op :try :e node}))

(defn- parse-bracket
  "Parses the suffix after a `[` (already consumed) on `term`."
  [st term]
  (cond
    (op? (peek-tok st) "]")
    (do (advance! st) {:op :iterate :term term})

    (op? (peek-tok st) ":")
    (do (advance! st)
        (let [to (parse-pipe st)]
          (expect-op! st "]")
          {:op :slice :term term :from nil :to to}))

    :else
    (let [e (parse-pipe st)]
      (if (op? (peek-tok st) ":")
        (do (advance! st)
            (if (op? (peek-tok st) "]")
              (do (advance! st) {:op :slice :term term :from e :to nil})
              (let [to (parse-pipe st)]
                (expect-op! st "]")
                {:op :slice :term term :from e :to to})))
        (do (expect-op! st "]")
            {:op :index :term term :idx e})))))

(defn- parse-postfix
  "Parses a primary and its suffixes. When `allow-as` is true, a trailing
  `as $x | body` turns the term into a variable binding."
  [st allow-as]
  (loop [node (parse-primary st)]
    (let [t (peek-tok st)]
      (cond
        (op? t "?") (do (advance! st) (recur (make-opt node)))

        (and t (= :field (t 0)))
        (do (advance! st) (recur {:op :index :term node :idx (lit (t 1))}))

        (and (op? t ".") (= :str (get (peek-tok st 1) 0)))
        (let [s ((peek-tok st 1) 1)]
          (advance! st) (advance! st)
          (recur {:op :index :term node :idx (lit s)}))

        (and (op? t ".") (op? (peek-tok st 1) "["))
        (do (advance! st) (advance! st) (recur (parse-bracket st node)))

        (op? t "[")
        (do (advance! st) (recur (parse-bracket st node)))

        (and allow-as (id? t "as"))
        (do (advance! st)
            (let [name (expect-var! st)]
              (expect-op! st "|")
              {:op :bind :src node :name name :body (parse-pipe st)}))

        :else node))))

;; --- primaries

(defn- parse-object-value [st]
  (letfn [(objterm [st]
            (if (op? (peek-tok st) "-")
              (do (advance! st) {:op :neg :e (objterm st)})
              (parse-postfix st false)))]
    (loop [l (objterm st)]
      (if (op? (peek-tok st) "|")
        (do (advance! st) (recur {:op :pipe :l l :r (objterm st)}))
        l))))

(defn- parse-object-entry [st]
  (let [t (peek-tok st)
        kind (when t (t 0))]
    (cond
      (and (#{:id :str} kind) (op? (peek-tok st 1) ":"))
      (do (advance! st) (advance! st)
          [(lit (t 1)) (parse-object-value st)])

      (#{:id :str} kind)
      (do (advance! st)
          [(lit (t 1)) {:op :index :term {:op :identity} :idx (lit (t 1))}])

      (= :var kind)
      (do (advance! st)
          [(lit (t 1)) {:op :var :name (t 1)}])

      (op? t "(")
      (do (advance! st)
          (let [k (parse-pipe st)]
            (expect-op! st ")")
            (expect-op! st ":")
            [k (parse-object-value st)]))

      :else (fail st "bad object entry"))))

(defn- parse-object [st]
  (if (op? (peek-tok st) "}")
    (do (advance! st) {:op :object :entries []})
    (loop [entries [(parse-object-entry st)]]
      (cond
        (op? (peek-tok st) ",") (do (advance! st) (recur (conj entries (parse-object-entry st))))
        :else (do (expect-op! st "}") {:op :object :entries entries})))))

(defn- parse-if [st]
  (let [c (parse-pipe st)]
    (expect-id! st "then")
    (let [th (parse-pipe st)
          t (peek-tok st)]
      (cond
        (id? t "elif") (do (advance! st) {:op :if :cond c :then th :else (parse-if st)})
        (id? t "else") (do (advance! st)
                           (let [el (parse-pipe st)]
                             (expect-id! st "end")
                             {:op :if :cond c :then th :else el}))
        :else (do (expect-id! st "end") {:op :if :cond c :then th :else nil})))))

(defn- parse-reduce [st]
  (let [src (parse-postfix st false)]
    (expect-id! st "as")
    (let [name (expect-var! st)]
      (expect-op! st "(")
      (let [init (parse-pipe st)]
        (expect-op! st ";")
        (let [upd (parse-pipe st)]
          (expect-op! st ")")
          {:op :reduce :src src :name name :init init :update upd})))))

(defn- parse-call [st name]
  (if (op? (peek-tok st) "(")
    (do (advance! st)
        (loop [args [(parse-pipe st)]]
          (cond
            (op? (peek-tok st) ";") (do (advance! st) (recur (conj args (parse-pipe st))))
            :else (do (expect-op! st ")") {:op :call :name name :args args}))))
    {:op :call :name name :args []}))

(defn- parse-primary [st]
  (let [t (peek-tok st)]
    (when-not t (fail st "unexpected end of filter"))
    (let [[kind v] t]
      (case kind
        :num (do (advance! st) (lit v))
        :str (do (advance! st) (lit v))
        :var (do (advance! st) {:op :var :name v})
        :field (do (advance! st) {:op :index :term {:op :identity} :idx (lit v)})
        :id (do (advance! st)
                (case v
                  "true" (lit true)
                  "false" (lit false)
                  "null" (lit nil)
                  "if" (parse-if st)
                  "reduce" (parse-reduce st)
                  (parse-call st v)))
        :op (case v
              "." (do (advance! st)
                      (if-let [t2 (peek-tok st)]
                        (if (= :str (t2 0))
                          (do (advance! st) {:op :index :term {:op :identity} :idx (lit (t2 1))})
                          {:op :identity})
                        {:op :identity}))
              "(" (do (advance! st)
                      (let [e (parse-pipe st)]
                        (expect-op! st ")")
                        {:op :paren :e e}))
              "[" (do (advance! st)
                      (if (op? (peek-tok st) "]")
                        (do (advance! st) {:op :array :e nil})
                        (let [e (parse-pipe st)]
                          (expect-op! st "]")
                          {:op :array :e e})))
              "{" (do (advance! st) (parse-object st))
              (fail st (str "unexpected '" v "'")))))))

(defn parse
  "Parses filter source text into a syntax tree (see the namespace doc).
  Throws `ex-info` with `{:type :jq/parse-error}` on malformed filters."
  [^String src]
  (let [st {:toks (lexer/tokenize src) :pos (volatile! 0)}
        ast (parse-pipe st)]
    (when (peek-tok st) (fail st "unexpected trailing tokens"))
    ast))
