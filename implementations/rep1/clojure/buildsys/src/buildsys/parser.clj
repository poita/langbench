(ns buildsys.parser
  "The Kiln Build Language parser.

  [[parse-file]] turns build file text into a vector of statement nodes.

  Expression nodes:

      [:lit v]            [:interp parts]      [:var name]
      [:list exprs]       [:unop op e]         [:binop op l r]
      [:call name args]   [:index x i]

  Statement nodes:

      [:let name e]  [:set name e]  [:include e]  [:abort e]  [:default e]
      [:phony name e]  [:use name args]  [:when branches else-body]
      [:each index-name-or-nil name e body]  [:rule name params body]
      [:step fields]

  A `use` argument is `[:pos e]` or `[:kw name e]`; a rule parameter is
  `{:name n :default e-or-nil}`; a step field is `[:out e]`, `[:in e]`,
  `[:after e]`, `[:cost e]`, `[:depfile e]` or `[:cmd name args]`."
  (:require [buildsys.error :as err]
            [buildsys.lexer :as lexer]))

(set! *warn-on-reflection* true)

(def reserved-words
  #{"abort" "after" "cmd" "cost" "default" "depfile" "each" "elsewhen"
    "false" "in" "include" "let" "otherwise" "out" "phony" "rule" "set"
    "step" "true" "use" "when"})

;; ---------------------------------------------------------------------------
;; Token cursor

(defn- cursor [file line ts] {:file file :line line :ts ts :i (volatile! 0)})

(defn- perr [cur] (err/parse-error (:file cur) (:line cur)))

(defn- peek-tok
  ([cur] (peek-tok cur 0))
  ([cur k] (get (:ts cur) (+ @(:i cur) k))))

(defn- advance! [cur] (vswap! (:i cur) inc))

(defn- done? [cur] (>= @(:i cur) (count (:ts cur))))

(defn- op? [tok s] (and tok (= :op (tok 0)) (= s (tok 1))))
(defn- id? ([tok] (and tok (= :id (tok 0))))
  ([tok s] (and tok (= :id (tok 0)) (= s (tok 1)))))

(defn- accept-op! [cur s]
  (when (op? (peek-tok cur) s) (advance! cur) true))

(defn- expect-op! [cur s]
  (if (accept-op! cur s) true (perr cur)))

(defn- expect-name!
  "Consume an identifier that is not a reserved word; return its text."
  [cur]
  (let [t (peek-tok cur)]
    (if (and (id? t) (not (reserved-words (t 1))))
      (do (advance! cur) (t 1))
      (perr cur))))

(defn- expect-any-name!
  "Consume an identifier in a namespace of its own (reserved words allowed)."
  [cur]
  (let [t (peek-tok cur)]
    (if (id? t) (do (advance! cur) (t 1)) (perr cur))))

;; ---------------------------------------------------------------------------
;; Expressions

(declare parse-expr parse-string)

(defn- parse-args
  "Parse `expr {, expr} [,]` up to (and including) the `close` operator.  The
  opening bracket has already been consumed."
  [cur close]
  (if (accept-op! cur close)
    []
    (loop [args [(parse-expr cur)]]
      (cond
        (accept-op! cur ",") (if (accept-op! cur close)
                               args
                               (recur (conj args (parse-expr cur))))
        (accept-op! cur close) args
        :else (perr cur)))))

(defn- parse-primary [cur]
  (let [t (peek-tok cur)]
    (when-not t (perr cur))
    (case (t 0)
      :int (do (advance! cur) [:lit (t 1)])
      :str (do (advance! cur) (parse-string cur (t 1)))
      :id (if (op? (peek-tok cur 1) "(")
            (do (advance! cur) (advance! cur)
                [:call (t 1) (parse-args cur ")")])
            (case (t 1)
              "true" (do (advance! cur) [:lit true])
              "false" (do (advance! cur) [:lit false])
              (do (advance! cur)
                  (if (reserved-words (t 1)) (perr cur) [:var (t 1)]))))
      :op (case (t 1)
            "(" (do (advance! cur)
                    (let [e (parse-expr cur)]
                      (expect-op! cur ")")
                      e))
            "[" (do (advance! cur) [:list (parse-args cur "]")])
            (perr cur)))))

(defn- parse-postfix [cur]
  (loop [e (parse-primary cur)]
    (let [t (peek-tok cur)]
      (cond
        (op? t "[") (do (advance! cur)
                        (let [i (parse-expr cur)]
                          (expect-op! cur "]")
                          (recur [:index e i])))
        (op? t "(") (perr cur)
        :else e))))

(defn- parse-unary [cur]
  (let [t (peek-tok cur)]
    (cond
      (op? t "!") (do (advance! cur) [:unop "!" (parse-unary cur)])
      (op? t "-") (do (advance! cur) [:unop "-" (parse-unary cur)])
      :else (parse-postfix cur))))

(defn- left-assoc
  "A parser for a left-associative binary level over `sub`, with operators `ops`."
  [sub ops]
  (fn [cur]
    (loop [l (sub cur)]
      (let [t (peek-tok cur)]
        (if (and t (= :op (t 0)) (ops (t 1)))
          (do (advance! cur)
              (recur [:binop (t 1) l (sub cur)]))
          l)))))

(def ^:private parse-mul (left-assoc parse-unary #{"*" "/" "%"}))
(def ^:private parse-add (left-assoc parse-mul #{"+" "-"}))
(def ^:private parse-str (left-assoc parse-add #{"~"}))
(def ^:private parse-cat (left-assoc parse-str #{"++"}))
(def ^:private parse-cmp (left-assoc parse-cat #{"==" "!=" "<" "<=" ">" ">="}))
(def ^:private parse-and (left-assoc parse-cmp #{"&&"}))
(def ^:private parse-or (left-assoc parse-and #{"||"}))

(defn- parse-pipe [cur]
  (loop [l (parse-or cur)]
    (if (accept-op! cur "|>")
      (let [name (expect-any-name! cur)
            args (if (accept-op! cur "(") (parse-args cur ")") [])]
        (recur [:call name (into [l] args)]))
      l)))

(defn- parse-expr [cur] (parse-pipe cur))

(defn- parse-complete-expr
  "Parse tokens `ts` as exactly one expression; E_PARSE on empty or leftover."
  [cur ts]
  (let [c (cursor (:file cur) (:line cur) ts)]
    (when (empty? ts) (perr c))
    (let [e (parse-expr c)]
      (when-not (done? c) (perr c))
      e)))

;; ---------------------------------------------------------------------------
;; String literals

(defn- parse-string
  "Parse the raw literal token text `raw` into `[:lit s]` or `[:interp parts]`."
  [cur ^String raw]
  (if (= \' (.charAt raw 0))
    (let [body (subs raw 1 (dec (.length raw)))]
      [:lit (.replace body "''" "'")])
    (let [body (subs raw 1 (dec (.length raw)))
          n (.length body)
          sb (StringBuilder.)]
      (loop [i 0 parts []]
        (let [flush (fn [] (if (pos? (.length sb))
                             (let [s (str sb)] (.setLength sb 0) (conj parts s))
                             parts))]
          (if (>= i n)
            (let [parts (flush)]
              (cond
                (empty? parts) [:lit ""]
                (and (= 1 (count parts)) (string? (first parts))) [:lit (first parts)]
                :else [:interp parts]))
            (let [c (.charAt body i)]
              (case c
                \\ (let [d (when (< (inc i) n) (.charAt body (inc i)))]
                     (.append sb (case d
                                   \\ \\
                                   \" \"
                                   \n \newline
                                   \t \tab
                                   \r \return
                                   \0 (char 0)
                                   (perr cur)))
                     (recur (+ i 2) parts))
                \{ (if (and (< (inc i) n) (= \{ (.charAt body (inc i))))
                     (do (.append sb \{) (recur (+ i 2) parts))
                     (let [e (lexer/skip-region body (inc i))]
                       (when-not e (perr cur))
                       (let [inner (subs body (inc i) (dec (long e)))
                             ts (lexer/tokenize inner #(perr cur))
                             expr (parse-complete-expr cur ts)
                             parts (flush)]
                         (recur (long e) (conj parts expr)))))
                \} (if (and (< (inc i) n) (= \} (.charAt body (inc i))))
                     (do (.append sb \}) (recur (+ i 2) parts))
                     (perr cur))
                (do (.append sb c) (recur (inc i) parts))))))))))

;; ---------------------------------------------------------------------------
;; Statements

(defn- parse-rest-expr
  "Parse the rest of the line's tokens as one complete expression."
  [cur]
  (let [ts (subvec (:ts cur) @(:i cur))
        e (parse-complete-expr cur ts)]
    (vreset! (:i cur) (count (:ts cur)))
    e))

(defn- parse-use-args [cur]
  (if (accept-op! cur ")")
    []
    (loop [args [] seen-kw? false]
      (let [t (peek-tok cur)
            kw? (and (id? t) (not (reserved-words (t 1))) (op? (peek-tok cur 1) "="))
            arg (if kw?
                  (do (advance! cur) (advance! cur) [:kw (t 1) (parse-expr cur)])
                  (do (when seen-kw? (perr cur)) [:pos (parse-expr cur)]))
            args (conj args arg)
            seen-kw? (or seen-kw? kw?)]
        (cond
          (accept-op! cur ",") (if (accept-op! cur ")") args (recur args seen-kw?))
          (accept-op! cur ")") args
          :else (perr cur))))))

(defn- finish! [cur node]
  (when-not (done? cur) (perr cur))
  node)

(defn- parse-simple
  "Parse a simple statement (not inside a step)."
  [cur]
  (let [kw ((peek-tok cur) 1)]
    (advance! cur)
    (case kw
      "let" (let [name (expect-name! cur)]
              (expect-op! cur "=")
              [:let name (parse-rest-expr cur)])
      "set" (let [name (expect-name! cur)]
              (expect-op! cur "=")
              [:set name (parse-rest-expr cur)])
      "phony" (let [name (expect-name! cur)]
                (expect-op! cur "=")
                [:phony name (parse-rest-expr cur)])
      "include" [:include (parse-rest-expr cur)]
      "abort" [:abort (parse-rest-expr cur)]
      "default" [:default (parse-rest-expr cur)]
      "use" (let [name (expect-any-name! cur)]
              (expect-op! cur "(")
              (finish! cur [:use name (parse-use-args cur)]))
      (perr cur))))

(defn- parse-step-field [cur]
  (let [kw ((peek-tok cur) 1)]
    (advance! cur)
    (case kw
      "out" [:out (parse-rest-expr cur)]
      "in" [:in (parse-rest-expr cur)]
      "after" [:after (parse-rest-expr cur)]
      "cost" [:cost (parse-rest-expr cur)]
      "depfile" [:depfile (parse-rest-expr cur)]
      "cmd" (let [name (expect-any-name! cur)]
              (expect-op! cur "(")
              (finish! cur [:cmd name (parse-args cur ")")]))
      (perr cur))))

(defn- body-ts
  "The tokens of a header line between the keyword and the final `{`."
  [ts from]
  (subvec ts from (dec (count ts))))

(defn- parse-params [cur]
  (if (accept-op! cur ")")
    []
    (loop [params [] names #{} defaulted? false]
      (let [name (expect-name! cur)
            _ (when (names name) (perr cur))
            default (when (accept-op! cur "=") (parse-expr cur))
            _ (when (and defaulted? (nil? default)) (perr cur))
            params (conj params {:name name :default default})
            names (conj names name)
            defaulted? (or defaulted? (some? default))]
        (cond
          (accept-op! cur ",") (if (accept-op! cur ")") params (recur params names defaulted?))
          (accept-op! cur ")") params
          :else (perr cur))))))

(defn- parse-header
  "Parse a block header line (last token `{`, first token not `}`).  Returns a
  frame."
  [file {:keys [line tokens]}]
  (let [ts tokens
        cur (cursor file line ts)
        t0 (first ts)
        kw (when (id? t0) (t0 1))]
    (case kw
      "step" (do (when-not (= 2 (count ts)) (perr cur))
                 {:kind :step :line line :body []})
      "when" (let [e (parse-complete-expr cur (body-ts ts 1))]
               {:kind :when :line line :cond e :branches [] :phase :when :body []})
      "each" (do (advance! cur)
                 (let [a (expect-name! cur)
                       b (when (accept-op! cur ",") (expect-name! cur))]
                   (when-not (id? (peek-tok cur) "in") (perr cur))
                   (advance! cur)
                   (when (= a b) (perr cur))
                   (let [e (parse-complete-expr cur (body-ts ts @(:i cur)))]
                     {:kind :each :line line :names (if b [a b] [nil a]) :expr e :body []})))
      "rule" (do (advance! cur)
                 (let [name (expect-name! cur)]
                   (expect-op! cur "(")
                   (let [params (parse-params cur)]
                     (when-not (and (op? (peek-tok cur) "{") (= (inc @(:i cur)) (count ts)))
                       (perr cur))
                     {:kind :rule :line line :name name :params params :body []})))
      (perr cur))))

(defn- close-frame
  "Turn a finished frame into a statement node."
  [frame]
  (case (:kind frame)
    :step [:step (:body frame)]
    :each (let [[i n] (:names frame)] [:each i n (:expr frame) (:body frame)])
    :rule [:rule (:name frame) (:params frame) (:body frame)]
    :when (if (= :else (:phase frame))
            [:when (:branches frame) (:body frame)]
            [:when (conj (:branches frame) [(:cond frame) (:body frame)]) nil])))

(defn- add-stmt [stack node]
  (let [top (peek stack)]
    (conj (pop stack) (update top :body conj node))))

(defn- handle-terminator
  "Handle a logical line whose first token is `}`.  Returns the new stack."
  [file stack {:keys [line tokens] :as ll}]
  (let [cur (cursor file line tokens)
        n (count tokens)
        top (peek stack)
        opens? (op? (peek tokens) "{")]
    (cond
      (= n 1)
      (if (= :file (:kind top))
        (perr cur)
        (add-stmt (pop stack) (close-frame top)))

      (and opens? (id? (tokens 1) "elsewhen"))
      (do (when-not (and (= :when (:kind top)) (= :when (:phase top))) (perr cur))
          (let [e (parse-complete-expr cur (subvec tokens 2 (dec n)))]
            (conj (pop stack)
                  (assoc top
                         :line line
                         :branches (conj (:branches top) [(:cond top) (:body top)])
                         :cond e :body []))))

      (and opens? (= n 3) (id? (tokens 1) "otherwise"))
      (do (when-not (and (= :when (:kind top)) (= :when (:phase top))) (perr cur))
          (conj (pop stack)
                (assoc top
                       :line line
                       :branches (conj (:branches top) [(:cond top) (:body top)])
                       :phase :else :body [])))

      :else (perr cur))))

(defn parse-file
  "Parse build file `text` (named `file`, used in error messages) into a vector
  of statement nodes.  Throws `E_PARSE` for the single error selected by the
  rules of SPEC.md: lexical errors first, then the first grammar error in file
  order, then the innermost unterminated block."
  [file text]
  (let [lines (lexer/lex file text)]
    (loop [lines (seq lines) stack [{:kind :file :line 0 :body []}]]
      (if-let [[{:keys [line tokens] :as ll} & more] lines]
        (let [cur (cursor file line tokens)
              first-tok (first tokens)
              top (peek stack)]
          (cond
            (op? first-tok "}")
            (recur more (handle-terminator file stack ll))

            (op? (peek tokens) "{")
            (do (when (= :step (:kind top)) (perr cur))
                (recur more (conj stack (parse-header file ll))))

            (= :step (:kind top))
            (do (when-not (id? first-tok) (perr cur))
                (recur more (add-stmt stack (parse-step-field cur))))

            :else
            (do (when-not (id? first-tok) (perr cur))
                (recur more (add-stmt stack (parse-simple cur))))))
        (if (> (count stack) 1)
          (err/parse-error file (:line (peek stack)))
          (:body (first stack)))))))
