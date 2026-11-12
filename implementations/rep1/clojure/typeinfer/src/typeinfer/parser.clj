(ns typeinfer.parser
  "Recursive-descent parser producing a plain-data syntax tree.

  ## Expression nodes (maps with an `:op` key)

      {:op :int}                       integer literal
      {:op :bool, :value true}         `true` / `false`
      {:op :unit}                      `()`
      {:op :nil}                       `[]`
      {:op :var, :name \"x\"}
      {:op :fun, :params [\"x\" ...], :body e}
      {:op :app, :fn f, :arg a}        one argument per node
      {:op :if, :cond c, :then a, :else b}
      {:op :let, :name n, :rhs e1, :body e2}
      {:op :letrec, :name n, :rhs e1, :body e2}   ; rhs is a :fun node
      {:op :tuple, :elems [e ...]}     two or more elements
      {:op :list, :elems [e ...]}      one or more elements
      {:op :cons, :head h, :tail t}    `h :: t`
      {:op :binop, :operator \"+\", :left l, :right r}

  ## Declarations

      {:kind :let,    :name n, :expr e}
      {:kind :letrec, :name n, :expr e}   ; e is a :fun node
      {:kind :expr,   :expr e}

  `let f x y = e` is desugared to `let f = fun x y -> e` here."
  (:require [typeinfer.lexer :as lexer]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Parser state: the token vector and a mutable position.

(deftype Parser [toks ^longs pos])

(defn- cur
  "The current token, or nil at the end of input."
  [^Parser p]
  (let [i (aget ^longs (.-pos p) 0)
        toks (.-toks p)]
    (when (< i (count toks)) (nth toks i))))

(defn- bump! [^Parser p]
  (let [^longs a (.-pos p)] (aset a 0 (inc (aget a 0)))))

(defn- syntax-error [^Parser p msg]
  (let [t (cur p)]
    (throw (ex-info (str "syntax error: " msg
                         (if t (str " at offset " (nth t 2) " near '" (nth t 1) "'")
                             " at end of input"))
                    {:kind :syntax :offset (some-> t (nth 2))}))))

(defn- at?
  "True when the current token is the keyword/symbol `text`."
  [^Parser p text]
  (let [t (cur p)]
    (boolean (and t (identical? :tok (nth t 0)) (= text (nth t 1))))))

(defn- at-kind? [^Parser p kind]
  (let [t (cur p)] (boolean (and t (identical? kind (nth t 0))))))

(defn- advance! [^Parser p] (let [t (cur p)] (bump! p) t))

(defn- accept! [^Parser p text]
  (when (at? p text) (bump! p) true))

(defn- expect! [^Parser p text]
  (if (at? p text) (bump! p) (syntax-error p (str "expected '" text "'"))))

(defn- expect-ident! [^Parser p]
  (if (at-kind? p :ident)
    (nth (advance! p) 1)
    (syntax-error p "expected an identifier")))

(defn- parse-idents [p]
  (loop [acc []]
    (if (at-kind? p :ident)
      (recur (conj acc (nth (advance! p) 1)))
      acc)))

;; ---------------------------------------------------------------------------
;; Expressions

(declare parse-expr)

(defn- atom-start? [^Parser p]
  (let [t (cur p)]
    (and t
         (case (nth t 0)
           (:int :ident) true
           :tok (case (nth t 1) ("true" "false" "(" "[") true false)))))

(defn- parse-atom [^Parser p]
  (let [t (advance! p)]
    (when-not t (syntax-error p "unexpected end of input"))
    (case (nth t 0)
      :int {:op :int}
      :ident {:op :var :name (nth t 1)}
      :tok
      (case (nth t 1)
        "true" {:op :bool :value true}
        "false" {:op :bool :value false}
        "(" (if (accept! p ")")
              {:op :unit}
              (let [e (parse-expr p)]
                (if (at? p ",")
                  (let [elems (loop [acc [e]]
                                (if (accept! p ",") (recur (conj acc (parse-expr p))) acc))]
                    (expect! p ")")
                    {:op :tuple :elems elems})
                  (do (expect! p ")") e))))
        "[" (if (accept! p "]")
              {:op :nil}
              (let [elems (loop [acc [(parse-expr p)]]
                            (if (accept! p ";") (recur (conj acc (parse-expr p))) acc))]
                (expect! p "]")
                {:op :list :elems elems}))
        (throw (ex-info (str "syntax error: unexpected '" (nth t 1) "' at offset " (nth t 2))
                            {:kind :syntax :offset (nth t 2)}))))))

(defn- parse-app [p]
  (loop [f (parse-atom p)]
    (if (atom-start? p)
      (recur {:op :app :fn f :arg (parse-atom p)})
      f)))

(defn- parse-left-assoc
  "Parse `operand (op operand)*` for the operators in `ops`, left-associative."
  [p operand ops]
  (loop [l (operand p)]
    (let [t (cur p)]
      (if (and t (identical? :tok (nth t 0)) (contains? ops (nth t 1)))
        (do (bump! p)
            (recur {:op :binop :operator (nth t 1) :left l :right (operand p)}))
        l))))

(def ^:private mul-ops #{"*" "/"})
(def ^:private add-ops #{"+" "-"})
(def ^:private cmp-ops #{"=" "<" ">" "<=" ">="})

(defn- parse-mul [p] (parse-left-assoc p parse-app mul-ops))
(defn- parse-add [p] (parse-left-assoc p parse-mul add-ops))

(defn- parse-cons [p]
  (let [h (parse-add p)]
    (if (accept! p "::")
      {:op :cons :head h :tail (parse-cons p)}
      h)))

(defn- parse-cmp [p]
  (let [l (parse-cons p)
        t (cur p)]
    (if (and t (identical? :tok (nth t 0)) (contains? cmp-ops (nth t 1)))
      (do (bump! p) {:op :binop :operator (nth t 1) :left l :right (parse-cons p)})
      l)))

(defn- parse-and [p] (parse-left-assoc p parse-cmp #{"&&"}))
(defn- parse-or [p] (parse-left-assoc p parse-and #{"||"}))

(defn- parse-binding
  "Parse `let [rec] name params = expr` (after which the caller decides what
  follows). Returns `[rec? name rhs]` with parameters folded into a `:fun`."
  [p]
  (expect! p "let")
  (let [rec? (accept! p "rec")
        name (expect-ident! p)
        params (parse-idents p)]
    (when (and rec? (empty? params))
      (syntax-error p "'let rec' requires at least one parameter"))
    (expect! p "=")
    (let [rhs (parse-expr p)]
      [rec? name (if (seq params) {:op :fun :params params :body rhs} rhs)])))

(defn parse-expr [p]
  (cond
    (at? p "let")
    (let [[rec? name rhs] (parse-binding p)]
      (expect! p "in")
      {:op (if rec? :letrec :let) :name name :rhs rhs :body (parse-expr p)})

    (at? p "fun")
    (do (bump! p)
        (let [params (parse-idents p)]
          (when (empty? params) (syntax-error p "expected a parameter"))
          (expect! p "->")
          {:op :fun :params params :body (parse-expr p)}))

    (at? p "if")
    (do (bump! p)
        (let [c (parse-expr p)
              _ (expect! p "then")
              a (parse-expr p)
              _ (expect! p "else")
              b (parse-expr p)]
          {:op :if :cond c :then a :else b}))

    :else (parse-or p)))

;; ---------------------------------------------------------------------------
;; Declarations and programs

(defn- parse-decl [p]
  (if (at? p "let")
    (let [[rec? name rhs] (parse-binding p)]
      (expect! p ";;")
      {:kind (if rec? :letrec :let) :name name :expr rhs})
    (let [e (parse-expr p)]
      (expect! p ";;")
      {:kind :expr :expr e})))

(defn parse-decls
  "Lazily parse `src` into a sequence of declarations. Lexical errors are
  thrown immediately; syntax errors are thrown when the offending declaration
  is realised, so earlier declarations remain usable."
  [^String src]
  (let [p (->Parser (lexer/tokenize src) (long-array 1))]
    ((fn step []
       (lazy-seq
        (when (cur p)
          (cons (parse-decl p) (step))))))))

(defn parse-program
  "Parse `src` eagerly into a vector of declarations (see the namespace doc).
  Throws `ex-info` with `{:kind :syntax}` on malformed input."
  [src]
  (vec (parse-decls src)))
