(ns scheme.analyzer
  "Analysis: turn a datum into a tree of `Node`s, once, before it runs.

  Each node is a `deftype` implementing `scheme.types/Node`. Variables are
  looked up by name at run time: innermost frame first, then the global
  environment (a `java.util.HashMap`). Nodes analysed with `tail?` true
  return a `TailCall` for procedure calls instead of performing them."
  (:require [scheme.runtime :as rt]
            [scheme.types :as t])
  (:import [java.util HashMap]
           [scheme.types Node Frame Pair Sym Closure Primitive TailCall]))

(set! *warn-on-reflection* true)

(defn- syntax-error [msg form]
  (ex-info (str "bad syntax: " msg) {:scheme/syntax-error msg :form form}))

;; ---------------------------------------------------------------------------
;; Variable access

(defn- lookup
  "Value of `s` in `env` or the global table `g`, or nil if unbound."
  [^HashMap g env s]
  (loop [e env]
    (if e
      (let [v (.getLocal ^Frame e s)]
        (if (nil? v) (recur (.-parent ^Frame e)) v))
      (.get g s))))

(deftype Const [v]
  Node (ev [_ _] v))

(deftype VarRef [^Sym sym ^HashMap g]
  Node
  (ev [_ env]
    (let [v (lookup g env sym)]
      (if (nil? v) (throw (t/scheme-error :unbound-variable)) v))))

(deftype Define [sym ^Node expr ^HashMap g]
  Node
  (ev [_ env]
    (let [v (.ev expr env)]
      (if env
        (.defineLocal ^Frame env sym v)
        (.put g sym v))
      t/VOID)))

(deftype SetBang [sym ^Node expr ^HashMap g]
  Node
  (ev [_ env]
    (let [v (.ev expr env)]
      (loop [e env]
        (if e
          (if (.setLocal ^Frame e sym v)
            t/VOID
            (recur (.-parent ^Frame e)))
          (if (.containsKey g sym)
            (do (.put g sym v) t/VOID)
            (throw (t/scheme-error :unbound-variable))))))))

;; ---------------------------------------------------------------------------
;; Control

(deftype If [^Node test ^Node then ^Node else]
  Node
  (ev [_ env]
    (if (false? (.ev test env))
      (if else (.ev else env) t/VOID)
      (.ev then env))))

(deftype Seq [^objects nodes]
  Node
  (ev [_ env]
    (let [last-i (dec (alength nodes))]
      (loop [i 0]
        (if (< i last-i)
          (do (.ev ^Node (aget nodes i) env) (recur (inc i)))
          (.ev ^Node (aget nodes last-i) env))))))

(deftype Cond [^objects tests ^objects bodies]
  Node
  (ev [_ env]
    (let [n (alength tests)]
      (loop [i 0]
        (if (< i n)
          (let [v (.ev ^Node (aget tests i) env)]
            (if (false? v)
              (recur (inc i))
              (if-let [body (aget bodies i)]
                (.ev ^Node body env)
                v)))
          t/VOID)))))

(deftype And [^objects nodes]
  Node
  (ev [_ env]
    (let [last-i (dec (alength nodes))]
      (loop [i 0]
        (if (< i last-i)
          (if (false? (.ev ^Node (aget nodes i) env))
            false
            (recur (inc i)))
          (.ev ^Node (aget nodes last-i) env))))))

(deftype Or [^objects nodes]
  Node
  (ev [_ env]
    (let [last-i (dec (alength nodes))]
      (loop [i 0]
        (if (< i last-i)
          (let [v (.ev ^Node (aget nodes i) env)]
            (if (false? v) (recur (inc i)) v))
          (.ev ^Node (aget nodes last-i) env))))))

;; ---------------------------------------------------------------------------
;; Procedures and application

(deftype Lambda [^objects params ^long nreq ^boolean variadic ^Node body]
  Node
  (ev [_ env] (Closure. params nreq variadic body env)))

(defn- eval-args
  "Evaluate `nodes` left to right into a fresh array."
  ^objects [^objects nodes env]
  (let [n (alength nodes)
        args (object-array n)]
    (loop [i 0]
      (when (< i n)
        (aset args i (.ev ^Node (aget nodes i) env))
        (recur (inc i))))
    args))

(deftype App [^Node fnode ^objects argnodes ^boolean tail?]
  Node
  (ev [_ env]
    (let [f (.ev fnode env)
          args (eval-args argnodes env)]
      (cond
        (not tail?) (rt/call f args)
        (instance? Primitive f) (rt/call-primitive f args)
        :else (TailCall. f args)))))

;; ---------------------------------------------------------------------------
;; Binding forms

(deftype Let [^objects syms ^objects inits ^Node body]
  Node
  (ev [_ env]
    (.ev body (t/make-frame syms (eval-args inits env) env))))

(deftype LetStar [^objects syms ^objects inits ^Node body]
  Node
  (ev [_ env]
    (let [n (alength syms)]
      (loop [i 0 e env]
        (if (< i n)
          (let [v (.ev ^Node (aget inits i) e)]
            (recur (inc i)
                   (t/make-frame (object-array [(aget syms i)]) (object-array [v]) e)))
          (.ev body e))))))

(deftype Letrec [^objects syms ^objects inits ^Node body]
  Node
  (ev [_ env]
    (let [n (alength syms)
          ^Frame frame (t/empty-frame n env)]
      (loop [i 0]
        (when (< i n)
          (.defineLocal frame (aget syms i) (.ev ^Node (aget inits i) frame))
          (recur (inc i))))
      (.ev body frame))))

(deftype NamedLet [name ^objects params ^objects inits ^Node body ^boolean tail?]
  Node
  (ev [_ env]
    (let [args (eval-args inits env)
          ;; `name` lives in a frame of its own between `env` and the call frame
          frame (t/make-frame (object-array [name]) (object-array 1) env)
          proc (Closure. params (alength params) false body frame)]
      (.setLocal frame name proc)
      (if tail? (TailCall. proc args) (rt/call proc args)))))

;; ---------------------------------------------------------------------------
;; The analyser proper

(declare analyze)

(defn- sym-named? [x ^String s]
  (and (instance? Sym x) (= (.name ^Sym x) s)))

(defn- form->vector [form what]
  (or (t/list->vector form)
      (throw (syntax-error (str "improper list in " what) form))))

(defn- analyze-seq
  "Analyse `forms` (a vector, at least one) as a body; the last is in tail
  position iff `tail?`."
  [g forms tail?]
  (when (empty? forms) (throw (syntax-error "empty body" nil)))
  (let [last-i (dec (count forms))
        nodes (object-array (map-indexed
                             (fn [i f] (analyze g f (and tail? (== i last-i))))
                             forms))]
    (if (== 1 (alength nodes)) (aget nodes 0) (Seq. nodes))))

(defn- parse-params
  "Returns [params-array nreq variadic?] for a lambda parameter spec."
  [spec]
  (loop [p spec acc []]
    (cond
      (instance? Pair p) (recur (.cdr ^Pair p) (conj acc (.car ^Pair p)))
      (t/nil-obj? p) [(object-array acc) (count acc) false]
      (instance? Sym p) [(object-array (conj acc p)) (count acc) true]
      :else (throw (syntax-error "bad parameter list" spec)))))

(defn- make-lambda [g spec body-forms]
  (let [[params nreq variadic] (parse-params spec)]
    (Lambda. params nreq variadic (analyze-seq g body-forms true))))

(defn- parse-bindings
  "Returns [syms-vector init-forms-vector] from a let-style binding list."
  [bindings]
  (let [bs (form->vector bindings "bindings")]
    [(mapv (fn [b] (.car ^Pair b)) bs)
     (mapv (fn [b] (.car ^Pair (.cdr ^Pair b))) bs)]))

(defn- analyze-define [g args]
  (let [target (.car ^Pair args)]
    (if (instance? Pair target)
      (Define. (.car ^Pair target)
               (make-lambda g (.cdr ^Pair target) (form->vector (.cdr ^Pair args) "define"))
               g)
      (Define. target (analyze g (.car ^Pair (.cdr ^Pair args)) false) g))))

(defn- analyze-let [g args tail?]
  (let [first-arg (.car ^Pair args)]
    (if (instance? Sym first-arg)
      (let [rest-args (.cdr ^Pair args)
            [syms inits] (parse-bindings (.car ^Pair rest-args))
            body (form->vector (.cdr ^Pair rest-args) "named let")]
        (NamedLet. first-arg (object-array syms)
                   (object-array (map #(analyze g % false) inits))
                   (analyze-seq g body true) tail?))
      (let [[syms inits] (parse-bindings first-arg)]
        (Let. (object-array syms)
              (object-array (map #(analyze g % false) inits))
              (analyze-seq g (form->vector (.cdr ^Pair args) "let") tail?))))))

(defn- analyze-cond [g args tail?]
  (let [clauses (form->vector args "cond")
        parsed (map (fn [c]
                      (let [parts (form->vector c "cond clause")
                            else? (sym-named? (first parts) "else")]
                        [(if else? (Const. true) (analyze g (first parts) false))
                         (when (seq (rest parts))
                           (analyze-seq g (vec (rest parts)) tail?))]))
                    clauses)]
    (Cond. (object-array (map first parsed)) (object-array (map second parsed)))))

(defn- analyze-operands
  "Analyse each of `forms`; only the last may be in tail position."
  [g forms tail?]
  (let [last-i (dec (count forms))]
    (object-array (map-indexed (fn [i f] (analyze g f (and tail? (== i last-i)))) forms))))

(defn- analyze-special [g name args form tail?]
  (case name
    "quote" (Const. (.car ^Pair args))
    "if" (let [parts (form->vector args "if")]
           (If. (analyze g (nth parts 0) false)
                (analyze g (nth parts 1) tail?)
                (when (> (count parts) 2) (analyze g (nth parts 2) tail?))))
    "define" (analyze-define g args)
    "set!" (SetBang. (.car ^Pair args) (analyze g (.car ^Pair (.cdr ^Pair args)) false) g)
    "lambda" (make-lambda g (.car ^Pair args) (form->vector (.cdr ^Pair args) "lambda"))
    "let" (analyze-let g args tail?)
    "let*" (let [[syms inits] (parse-bindings (.car ^Pair args))]
             (LetStar. (object-array syms)
                       (object-array (map #(analyze g % false) inits))
                       (analyze-seq g (form->vector (.cdr ^Pair args) "let*") tail?)))
    "letrec" (let [[syms inits] (parse-bindings (.car ^Pair args))]
               (Letrec. (object-array syms)
                        (object-array (map #(analyze g % false) inits))
                        (analyze-seq g (form->vector (.cdr ^Pair args) "letrec") tail?)))
    "begin" (analyze-seq g (form->vector args "begin") tail?)
    "cond" (analyze-cond g args tail?)
    "and" (let [forms (form->vector args "and")]
            (if (empty? forms) (Const. true) (And. (analyze-operands g forms tail?))))
    "or" (let [forms (form->vector args "or")]
           (if (empty? forms) (Const. false) (Or. (analyze-operands g forms tail?))))
    nil))

(def ^:private special-forms
  #{"quote" "if" "define" "set!" "lambda" "let" "let*" "letrec" "begin" "cond" "and" "or"})

(defn analyze
  "Analyse `form` into a Node for the global table `g`. `tail?` says whether
  the form is in tail position."
  [^HashMap g form tail?]
  (cond
    (instance? Sym form) (VarRef. form g)
    (instance? Pair form)
    (let [^Pair p form
          head (.car p)]
      (if (and (instance? Sym head) (contains? special-forms (.name ^Sym head)))
        (analyze-special g (.name ^Sym head) (.cdr p) form tail?)
        (App. (analyze g head false)
              (object-array (map #(analyze g % false)
                                 (form->vector (.cdr p) "application")))
              tail?)))
    :else (Const. form)))
