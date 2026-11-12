(ns langvm.parser
  "Recursive-descent parser (SPEC section 4).

  `(parse-module tokens)` returns a vector of item maps.  Every node is a map
  with a discriminating key (`:i` for items, `:ty` for types, `:e` for
  expressions, `:s` for statements, `:p` for patterns) and a packed `:pos`.
  See the node constructors below for the shapes."
  (:require [langvm.diag :as diag]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; token cursor

(def ^:dynamic *toks* nil)
(def ^:dynamic *cursor* nil)

(defn- idx ^long [] (aget ^longs *cursor* 0))
(defn- tok [^long k] (let [^objects ts *toks*] (aget ts (min (+ (idx) k) (dec (alength ts))))))
(defn- kind-at [^long k] (nth (tok k) 0))
(defn- kind [] (kind-at 0))
(defn- val-at [k] (nth (tok k) 1))
(defn- pos-at ^long [^long k] (nth (tok k) 2))
(defn- cur-pos ^long [] (pos-at 0))
(defn- advance! [] (let [t (tok 0)] (when (< (idx) (dec (alength ^objects *toks*))) (aset ^longs *cursor* 0 (inc (idx)))) t))
(defn- at? [k] (= k (kind)))
(defn- fail-here [] (diag/fail :parse (cur-pos)))
(defn- expect! [k] (if (at? k) (advance!) (fail-here)))
(defn- accept! [k] (when (at? k) (advance!)))

(defn- expect-ident!
  "Consume an identifier, returning [name pos]."
  []
  (if (at? :ident)
    (let [[_ v p] (advance!)] [v p])
    (fail-here)))

(declare comma-list)

(defn- comma-list1
  "Like [[comma-list]] but the list must have at least one item: an immediately
  following `close` is a parse error at that token."
  [close item-fn]
  (when (at? close) (fail-here))
  (comma-list close item-fn))

(defn- comma-list
  "Parse `item`s separated by commas (trailing comma allowed) until the closing
  token `close`, which is consumed.  At least one item unless `empty-ok`."
  [close item-fn]
  (loop [acc []]
    (cond
      (at? close) (do (advance!) acc)
      :else
      (let [it (item-fn)
            acc (conj acc it)]
        (cond
          (accept! ",") (recur acc)
          (at? close) (do (advance!) acc)
          :else (fail-here))))))

;; ---------------------------------------------------------------------------
;; types

(declare parse-type parse-expr parse-block parse-pattern)

;; closing of `>` / `>>`: split a `>>` in place
(defn- recur-close [acc]
  (cond
    (at? ">") (do (advance!) acc)
    (at? ">>") (let [p (cur-pos)
                     i (idx)]
                 (aset ^objects *toks* i [">" nil (inc p)])
                 acc)
    :else (fail-here)))

(defn- parse-type-args
  "Parse `< T, ... >` (current token is `<`)."
  []
  (advance!)
  (loop [acc []]
    (let [t (parse-type)
          acc (conj acc t)]
      (cond
        (accept! ",")
        (if (or (at? ">") (at? ">>")) (recur-close acc) (recur acc))
        :else (recur-close acc)))))

(defn parse-type []
  (let [p (cur-pos)]
    (case (kind)
      "[" (do (advance!)
              (let [t (parse-type)]
                (expect! "]")
                {:ty :list :elem t :pos p}))
      "#[" (do (advance!)
               (let [k (parse-type)]
                 (expect! ":")
                 (let [v (parse-type)]
                   (expect! "]")
                   {:ty :map :key k :val v :pos p})))
      "(" (do (advance!)
              (let [t1 (parse-type)]
                (expect! ",")
                (let [rest (comma-list1 ")" parse-type)]
                  {:ty :tuple :elems (into [t1] rest) :pos p})))
      "fn" (do (advance!)
               (expect! "(")
               (let [params (comma-list ")" parse-type)
                     ret (when (accept! "->") (parse-type))]
                 {:ty :fn :params params :ret ret :pos p}))
      :ident (let [[a ap] (expect-ident!)]
               (if (accept! "::")
                 (let [[b bp] (expect-ident!)]
                   {:ty :path :mod a :mod-pos ap :name b :name-pos bp
                    :args (when (at? "<") (parse-type-args)) :pos p})
                 {:ty :path :mod nil :name a :name-pos ap
                  :args (when (at? "<") (parse-type-args)) :pos p}))
      (fail-here))))

;; ---------------------------------------------------------------------------
;; patterns

(defn- parse-path-parts
  "ident [:: ident] -> {:mod :mod-pos :name :name-pos :pos}"
  []
  (let [p (cur-pos)
        [a ap] (expect-ident!)]
    (if (accept! "::")
      (let [[b bp] (expect-ident!)]
        {:mod a :mod-pos ap :name b :name-pos bp :pos p})
      {:mod nil :name a :name-pos ap :pos p})))

(defn- parse-struct-pattern [path p]
  (expect! ".")
  (expect! "{")
  (loop [fields [], rest? false]
    (cond
      (at? "}") (do (advance!) {:p :struct :path path :fields fields :rest? rest? :pos p})
      (at? "..") (do (advance!) (expect! "}")
                     {:p :struct :path path :fields fields :rest? true :pos p})
      :else
      (let [fp (cur-pos)
            [fname _] (expect-ident!)
            sub (when (accept! ":") (parse-pattern))
            fields (conj fields {:name fname :pos fp :pat sub})]
        (cond
          (accept! ",") (recur fields rest?)
          (at? "}") (recur fields rest?)
          :else (fail-here))))))

(defn parse-pattern []
  (let [p (cur-pos)]
    (case (kind)
      "_" (do (advance!) {:p :wild :pos p})
      :int (let [[_ v _] (advance!)] {:p :lit :kind :int :v v :pos p})
      :float (let [[_ v _] (advance!)] {:p :lit :kind :float :v v :pos p})
      :str (let [[_ v _] (advance!)] {:p :lit :kind :str :v v :pos p})
      :char (let [[_ v _] (advance!)] {:p :lit :kind :char :v v :pos p})
      "true" (do (advance!) {:p :lit :kind :bool :v true :pos p})
      "false" (do (advance!) {:p :lit :kind :bool :v false :pos p})
      "-" (do (advance!)
              (cond
                (at? :int) (let [[_ v _] (advance!)] {:p :lit :kind :int :v (unchecked-negate (long v)) :pos p})
                (at? :float) (let [[_ v _] (advance!)] {:p :lit :kind :float :v v :pos p})
                :else (fail-here)))
      "(" (do (advance!)
              (let [p1 (parse-pattern)]
                (expect! ",")
                (let [rest (comma-list1 ")" parse-pattern)]
                  {:p :tuple :elems (into [p1] rest) :pos p})))
      "[" (do (advance!)
              (loop [elems []]
                (cond
                  (at? "]") (do (advance!) {:p :list :elems elems :rest nil :pos p})
                  (at? "..")
                  (do (advance!)
                      (let [rest (if (at? :ident) (let [[_ v rp] (advance!)] {:name v :pos rp}) :anon)]
                        (expect! "]")
                        {:p :list :elems elems :rest rest :pos p}))
                  :else
                  (let [e (parse-pattern)
                        elems (conj elems e)]
                    (cond
                      (accept! ",") (recur elems)
                      (at? "]") (recur elems)
                      :else (fail-here))))))
      :ident
      (let [path (parse-path-parts)]
        (cond
          (and (at? ".") (= "{" (kind-at 1)))
          (parse-struct-pattern path p)
          (at? "(")
          (do (advance!)
              (let [args (comma-list1 ")" parse-pattern)]
                {:p :variant :path path :args args :pos p}))
          (:mod path) {:p :variant :path path :args nil :pos p}
          :else {:p :name :name (:name path) :pos p}))
      (fail-here))))

;; ---------------------------------------------------------------------------
;; expressions

(defn- parse-args
  "Arguments up to and including the closing `)`."
  []
  (comma-list ")" parse-expr))

(defn- binary-level
  "Build a left-associative binary-operator parser."
  [ops next-fn]
  (fn []
    (loop [l (next-fn)]
      (let [k (kind)]
        (if (contains? ops k)
          (do (advance!)
              (let [r (next-fn)]
                (recur {:e :binary :op k :l l :r r :pos (:pos l)})))
          l)))))

(declare parse-unary parse-postfix)

(def ^:private parse-mul (binary-level #{"*" "/" "%"} (fn [] (parse-unary))))
(def ^:private parse-add (binary-level #{"+" "-" "++"} (fn [] (parse-mul))))
(def ^:private parse-shift (binary-level #{"<<" ">>"} (fn [] (parse-add))))
(def ^:private parse-band (binary-level #{"&"} (fn [] (parse-shift))))
(def ^:private parse-bxor (binary-level #{"^"} (fn [] (parse-band))))
(def ^:private parse-bor (binary-level #{"|"} (fn [] (parse-bxor))))

(defn- parse-cmp []
  (let [l (parse-bor)
        k (kind)]
    (if (contains? #{"==" "!=" "<" "<=" ">" ">="} k)
      (do (advance!)
          (let [r (parse-bor)]
            {:e :binary :op k :l l :r r :pos (:pos l)}))
      l)))

(def ^:private parse-and (binary-level #{"&&"} (fn [] (parse-cmp))))
(def ^:private parse-or (binary-level #{"||"} (fn [] (parse-and))))

(defn parse-expr [] (parse-or))

(defn- parse-unary []
  (let [k (kind)]
    (if (contains? #{"-" "!" "~"} k)
      (let [p (cur-pos)]
        (advance!)
        {:e :unary :op k :x (parse-unary) :pos p})
      (parse-postfix))))

(defn- parse-lambda []
  (let [p (cur-pos)
        params (if (at? "||")
                 (do (advance!) [])
                 (do (advance!)
                     (comma-list1 "|"
                                  (fn []
                                    (let [[nm np] (expect-ident!)
                                          ty (when (accept! ":") (parse-type))]
                                      {:name nm :pos np :ty ty})))))
        ret (when (accept! "->") (parse-type))
        body (if (at? "{") (parse-block) (parse-expr))]
    {:e :lambda :params params :ret ret :ret-pos (when ret (:pos ret)) :body body :pos p}))

(defn- parse-if []
  (let [p (cur-pos)]
    (advance!)
    (let [c (parse-expr)
          then (parse-block)
          els (when (accept! "else")
                (if (at? "if") (parse-if) (parse-block)))]
      {:e :if :c c :then then :else els :pos p})))

(defn- parse-arm []
  (let [p (cur-pos)
        pat (parse-pattern)
        guard (when (accept! "when") (parse-expr))]
    (expect! "->")
    (let [block? (at? "{")
          body (if block? (parse-block) (parse-expr))]
      {:pat pat :guard guard :body body :block? block? :pos p})))

(defn- parse-match []
  (let [p (cur-pos)]
    (advance!)
    (let [scrut (parse-expr)]
      (expect! "{")
      (loop [arms []]
        (if (at? "}")
          (do (advance!) {:e :match :scrut scrut :arms arms :pos p})
          (let [arm (parse-arm)
                arms (conj arms arm)]
            (cond
              (accept! ",") (recur arms)
              (at? "}") (recur arms)
              (:block? arm) (recur arms)
              :else (fail-here))))))))

(defn- parse-path-expr []
  (let [path (parse-path-parts)
        node (assoc path :e :path)]
    (if (and (at? ".") (= "{" (kind-at 1)))
      (do (advance!) (advance!)
          (let [fields (comma-list "}"
                                   (fn []
                                     (let [fp (cur-pos)
                                           [fname _] (expect-ident!)]
                                       (expect! ":")
                                       {:name fname :pos fp :expr (parse-expr)})))]
            {:e :struct-lit :path node :fields fields :pos (:pos node)}))
      node)))

(defn- parse-primary []
  (let [p (cur-pos)]
    (case (kind)
      :int (let [[_ v _] (advance!)] {:e :int :v v :pos p})
      :float (let [[_ v _] (advance!)] {:e :float :v v :pos p})
      :str (let [[_ v _] (advance!)] {:e :str :v v :pos p})
      :char (let [[_ v _] (advance!)] {:e :char :v v :pos p})
      "true" (do (advance!) {:e :bool :v true :pos p})
      "false" (do (advance!) {:e :bool :v false :pos p})
      "self" (do (advance!) {:e :self :pos p})
      "(" (do (advance!)
              (let [e (parse-expr)]
                (if (accept! ",")
                  (let [rest (comma-list1 ")" parse-expr)]
                    {:e :tuple :elems (into [e] rest) :pos p})
                  (do (expect! ")") e))))
      "[" (do (advance!) {:e :list :elems (comma-list "]" parse-expr) :pos p})
      "#[" (do (advance!)
               {:e :map
                :entries (comma-list "]" (fn []
                                           (let [k (parse-expr)]
                                             (expect! ":")
                                             [k (parse-expr)])))
                :pos p})
      ("||" "|") (parse-lambda)
      "if" (parse-if)
      "match" (parse-match)
      :ident (parse-path-expr)
      (fail-here))))

(defn- parse-postfix []
  (loop [e (parse-primary)]
    (case (kind)
      "(" (do (advance!) (recur {:e :call :callee e :args (parse-args) :pos (:pos e)}))
      "[" (do (advance!)
              (let [i (parse-expr)]
                (expect! "]")
                (recur {:e :index :x e :i i :pos (:pos e)})))
      "." (do (advance!)
              (let [[nm np] (expect-ident!)]
                (if (at? "(")
                  (do (advance!)
                      (recur {:e :mcall :recv e :name nm :name-pos np :args (parse-args) :pos (:pos e)}))
                  (recur {:e :field :x e :name nm :name-pos np :pos (:pos e)}))))
      e)))

;; ---------------------------------------------------------------------------
;; statements and blocks

(defn- if-or-match? [e] (contains? #{:if :match} (:e e)))

(defn- parse-stmt-expr
  "Expression statement, assignment, or trailing expression.  Returns
  `[:tail e]` or `[:stmt s]`."
  []
  (let [p (cur-pos)
        e (parse-expr)]
    (cond
      (accept! "=")
      (let [v (parse-expr)]
        (expect! ";")
        [:stmt {:s :assign :target e :value v :pos p}])
      (accept! ";") [:stmt {:s :expr :expr e :pos p}]
      (at? "}") [:tail e]
      (if-or-match? e) [:stmt {:s :expr :expr e :pos p}]
      :else (fail-here))))

(defn- parse-stmt-keyword []
  (let [p (cur-pos)]
    (case (kind)
      "let" (do (advance!)
                (let [pat (parse-pattern)
                      ty (when (accept! ":") (parse-type))]
                  (expect! "=")
                  (let [init (parse-expr)]
                    (expect! ";")
                    {:s :let :pat pat :ty ty :init init :pos p})))
      "var" (do (advance!)
                (let [[nm np] (expect-ident!)
                      ty (when (accept! ":") (parse-type))]
                  (expect! "=")
                  (let [init (parse-expr)]
                    (expect! ";")
                    {:s :var :name nm :name-pos np :ty ty :init init :pos p})))
      "return" (do (advance!)
                   (let [e (when-not (at? ";") (parse-expr))]
                     (expect! ";")
                     {:s :return :expr e :pos p}))
      "while" (do (advance!)
                  (let [c (parse-expr)]
                    {:s :while :c c :body (parse-block) :pos p}))
      "for" (do (advance!)
                (let [pat (parse-pattern)]
                  (expect! "in")
                  (let [e (parse-expr)
                        hi (when (accept! "..") (parse-expr))]
                    {:s :for :pat pat :iter e :hi hi :body (parse-block) :pos p})))
      "break" (do (advance!) (expect! ";") {:s :break :pos p})
      "continue" (do (advance!) (expect! ";") {:s :continue :pos p}))))

(defn parse-block []
  (let [p (cur-pos)]
    (expect! "{")
    (loop [stmts []]
      (cond
        (at? "}") (do (advance!) {:e :block :stmts stmts :tail nil :pos p})
        (contains? #{"let" "var" "return" "while" "for" "break" "continue"} (kind))
        (recur (conj stmts (parse-stmt-keyword)))
        :else
        (let [[k v] (parse-stmt-expr)]
          (if (= k :tail)
            (do (expect! "}") {:e :block :stmts stmts :tail v :pos p})
            (recur (conj stmts v))))))))

;; ---------------------------------------------------------------------------
;; items

(defn- parse-trait-ref []
  (let [p (cur-pos)
        [a ap] (expect-ident!)]
    (if (accept! "::")
      (let [[b bp] (expect-ident!)]
        {:mod a :mod-pos ap :name b :name-pos bp :pos p})
      {:mod nil :name a :name-pos ap :pos p})))

(defn- parse-generics
  "Optional `<A: B + C, D>`.  Bounds are only allowed when `bounds?`."
  [bounds?]
  (if-not (at? "<")
    []
    (do (advance!)
        (comma-list1 ">"
                             (fn []
                               (let [[nm np] (expect-ident!)
                                     bounds (if (and bounds? (accept! ":"))
                                              (loop [acc [(parse-trait-ref)]]
                                                (if (accept! "+")
                                                  (recur (conj acc (parse-trait-ref)))
                                                  acc))
                                              [])]
                                 {:name nm :pos np :bounds bounds}))))))

(defn- parse-params []
  (comma-list ")" (fn []
                    (let [[nm np] (expect-ident!)]
                      (expect! ":")
                      {:name nm :pos np :ty (parse-type)}))))

(defn- parse-method-params
  "After `(`: `self [, Params] )`."
  []
  (expect! "self")
  (if (accept! ",")
    (do (when (at? ")") (fail-here)) (parse-params))
    (do (expect! ")") [])))

(defn- parse-fn-decl [pub?]
  (let [p (cur-pos)]
    (expect! "fn")
    (let [[nm np] (expect-ident!)
          tps (parse-generics true)]
      (expect! "(")
      (let [params (parse-params)
            ret (when (accept! "->") (parse-type))
            body (parse-block)]
        {:i :fn :pub pub? :name nm :name-pos np :tparams tps :params params
         :ret ret :body body :pos p}))))

(defn- parse-struct-decl [pub?]
  (let [p (cur-pos)]
    (advance!)
    (let [[nm np] (expect-ident!)
          tps (parse-generics false)]
      (expect! "{")
      (let [fields (comma-list "}" (fn []
                                     (let [[fname fp] (expect-ident!)]
                                       (expect! ":")
                                       {:name fname :pos fp :ty (parse-type)})))]
        {:i :struct :pub pub? :name nm :name-pos np :tparams tps :fields fields :pos p}))))

(defn- parse-enum-decl [pub?]
  (let [p (cur-pos)]
    (advance!)
    (let [[nm np] (expect-ident!)
          tps (parse-generics false)]
      (expect! "{")
      (let [variants (comma-list "}" (fn []
                                       (let [[vn vp] (expect-ident!)
                                             payload (if (accept! "(")
                                                       (comma-list1 ")" parse-type)
                                                       [])]
                                         {:name vn :pos vp :payload payload})))]
        {:i :enum :pub pub? :name nm :name-pos np :tparams tps :variants variants :pos p}))))

(defn- parse-method [allow-no-body?]
  (let [p (cur-pos)]
    (expect! "fn")
    (let [[nm np] (expect-ident!)]
      (expect! "(")
      (let [params (parse-method-params)
            ret (when (accept! "->") (parse-type))
            body (if (and allow-no-body? (accept! ";")) nil (parse-block))]
        {:name nm :name-pos np :params params :ret ret :body body :pos p}))))

(defn- parse-trait-decl [pub?]
  (let [p (cur-pos)]
    (advance!)
    (let [[nm np] (expect-ident!)]
      (expect! "{")
      (loop [ms []]
        (if (at? "}")
          (do (advance!) {:i :trait :pub pub? :name nm :name-pos np :methods ms :pos p})
          (recur (conj ms (parse-method true))))))))

(defn- parse-impl-decl []
  (let [p (cur-pos)]
    (advance!)
    (let [tps (parse-generics true)
          tr (parse-trait-ref)]
      (expect! "for")
      (let [head (parse-type)]
        (expect! "{")
        (loop [ms []]
          (if (at? "}")
            (do (advance!) {:i :impl :tparams tps :trait tr :head head :methods ms :pos p})
            (recur (conj ms (parse-method false)))))))))

(defn- parse-use []
  (let [p (cur-pos)]
    (advance!)
    (let [[nm np] (expect-ident!)
          alias (when (accept! "as") (expect-ident!))]
      (expect! ";")
      {:i :use :name nm :name-pos np :alias (first alias) :alias-pos (second alias) :pos p})))

(defn- parse-item []
  (case (kind)
    "use" (parse-use)
    "impl" (parse-impl-decl)
    "pub" (do (advance!)
              (case (kind)
                "fn" (parse-fn-decl true)
                "struct" (parse-struct-decl true)
                "enum" (parse-enum-decl true)
                "trait" (parse-trait-decl true)
                (fail-here)))
    "fn" (parse-fn-decl false)
    "struct" (parse-struct-decl false)
    "enum" (parse-enum-decl false)
    "trait" (parse-trait-decl false)
    (fail-here)))

(defn with-tokens
  "Run `f` with the parser cursor positioned at the start of `tokens`."
  [tokens f]
  (binding [*toks* (object-array tokens)
            *cursor* (long-array 1)]
    (f)))

(defn parse-module
  "Parse a token vector (from `langvm.lexer/lex`) into a vector of items."
  [tokens]
  (with-tokens tokens
    (fn []
      (loop [items []]
        (if (at? :eof)
          items
          (recur (conj items (parse-item))))))))

(defn parse-fn-item
  "Parse a single `fn` item from `tokens` (used for the built-in signatures)."
  [tokens]
  (with-tokens tokens #(parse-fn-decl false)))
