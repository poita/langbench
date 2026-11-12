(ns buildsys.parser
  "The KBL parser: turns lexed logical lines into a syntax tree.

  Statements are maps with an `:op`; expressions are vectors headed by a tag:

    [:const v]            [:var name]          [:list [expr ...]]
    [:interp [part ...]]  (part = string | expr)
    [:or a b] [:and a b]  [:bin op a b]        [:un op a]
    [:call name [expr ...]]                    [:index x i]

  Block structure is recovered line by line: a logical line ending in `{` opens
  a block, one starting with `}` closes (or, for `} elsewhen` / `} otherwise`,
  continues) one."
  (:require [buildsys.errors :as e]
            [buildsys.lexer :as lex]))

;; ---------------------------------------------------------------- cursor

(defn- cursor [tokens] {:ts tokens :n (count tokens) :i (volatile! 0)})

(defn- peek-at [c k]
  (let [i (+ @(:i c) k)] (when (< i (:n c)) (nth (:ts c) i))))
(defn- peek-tok [c] (peek-at c 0))
(defn- advance! [c] (vswap! (:i c) inc))
(defn- at-end? [c] (>= @(:i c) (:n c)))
(defn- expect-end! [c] (when-not (at-end? c) (e/parse-fail!)))

(defn- sym? [tok s] (and tok (= :sym (nth tok 0)) (= s (nth tok 1))))
(defn- id? [tok] (and tok (= :id (nth tok 0))))
(defn- word? [tok w] (and (id? tok) (= w (nth tok 1))))
(defn- plain-id?
  "An identifier token that is not a reserved word."
  [tok]
  (and (id? tok) (not (lex/reserved-words (nth tok 1)))))

(defn- eat-sym! [c s]
  (if (sym? (peek-tok c) s) (advance! c) (e/parse-fail!)))

(defn- ident! [c]
  (let [t (peek-tok c)]
    (if (plain-id? t) (do (advance! c) (nth t 1)) (e/parse-fail!))))

(defn- any-ident! [c]
  (let [t (peek-tok c)]
    (if (id? t) (do (advance! c) (nth t 1)) (e/parse-fail!))))

;; ------------------------------------------------------------ expressions

(declare parse-expr)

(defn- parse-seq
  "Parses `expr {, expr} [,]` up to and including the `close` symbol; the
  opening symbol has already been consumed."
  [c close]
  (if (sym? (peek-tok c) close)
    (do (advance! c) [])
    (loop [xs [(parse-expr c)]]
      (cond
        (sym? (peek-tok c) ",")
        (do (advance! c)
            (if (sym? (peek-tok c) close)
              (do (advance! c) xs)
              (recur (conj xs (parse-expr c)))))
        (sym? (peek-tok c) close) (do (advance! c) xs)
        :else (e/parse-fail!)))))

(defn- literal-expr [raw]
  (let [parts (lex/read-literal raw)]
    (if (and (= 1 (count parts)) (string? (first parts)))
      [:const (first parts)]
      (if (empty? parts)
        [:const ""]
        [:interp (mapv (fn [p]
                         (if (string? p)
                           p
                           (let [c (cursor (:tokens p))
                                 x (parse-expr c)]
                             (expect-end! c)
                             x)))
                       parts)]))))

(defn- parse-primary [c]
  (let [[kind v :as t] (peek-tok c)]
    (case kind
      :int (do (advance! c) [:const v])
      :str (do (advance! c) (literal-expr v))
      :id (do (advance! c)
              (cond
                (sym? (peek-tok c) "(")
                (do (advance! c) [:call v (parse-seq c ")")])
                (= v "true") [:const true]
                (= v "false") [:const false]
                (lex/reserved-words v) (e/parse-fail!)
                :else [:var v]))
      :sym (cond
             (= v "(") (do (advance! c)
                           (let [x (parse-expr c)] (eat-sym! c ")") x))
             (= v "[") (do (advance! c) [:list (parse-seq c "]")])
             :else (e/parse-fail!))
      (e/parse-fail!))))

(defn- parse-postfix [c]
  (loop [x (parse-primary c)]
    (let [t (peek-tok c)]
      (cond
        (sym? t "[") (do (advance! c)
                         (let [i (parse-expr c)] (eat-sym! c "]") (recur [:index x i])))
        (sym? t "(") (e/parse-fail!)
        :else x))))

(defn- parse-unary [c]
  (let [t (peek-tok c)]
    (cond
      (sym? t "!") (do (advance! c) [:un "!" (parse-unary c)])
      (sym? t "-") (do (advance! c) [:un "-" (parse-unary c)])
      :else (parse-postfix c))))

(def ^:private binary-levels
  "Binary operator levels, loosest first."
  [#{"||"} #{"&&"} #{"==" "!=" "<" "<=" ">" ">="} #{"++"} #{"~"} #{"+" "-"} #{"*" "/" "%"}])

(defn- parse-level [c level]
  (if (= level (count binary-levels))
    (parse-unary c)
    (let [ops (nth binary-levels level)]
      (loop [lhs (parse-level c (inc level))]
        (let [t (peek-tok c)]
          (if (and t (= :sym (nth t 0)) (ops (nth t 1)))
            (let [op (nth t 1)]
              (advance! c)
              (let [rhs (parse-level c (inc level))]
                (recur (case op
                         "||" [:or lhs rhs]
                         "&&" [:and lhs rhs]
                         [:bin op lhs rhs]))))
            lhs))))))

(defn- parse-expr [c]
  (loop [lhs (parse-level c 0)]
    (if (sym? (peek-tok c) "|>")
      (do (advance! c)
          (let [name (any-ident! c)
                args (if (sym? (peek-tok c) "(")
                       (do (advance! c) (parse-seq c ")"))
                       [])]
            (recur [:call name (into [lhs] args)])))
      lhs)))

(defn- parse-whole-expr
  "Parses tokens `ts` as exactly one expression."
  [ts]
  (let [c (cursor ts) x (parse-expr c)] (expect-end! c) x))

;; ------------------------------------------------------------- statements

(defn- parse-use [c]
  (let [rule (any-ident! c)]
    (eat-sym! c "(")
    (loop [pos [] kws []]
      (cond
        (sym? (peek-tok c) ")") (do (advance! c) (expect-end! c)
                                    {:op :use :name rule :pos pos :kw kws})
        :else
        (let [kw? (and (plain-id? (peek-tok c)) (sym? (peek-at c 1) "="))
              [pos kws] (if kw?
                          (let [k (ident! c)]
                            (advance! c)
                            [pos (conj kws [k (parse-expr c)])])
                          (do (when (seq kws) (e/parse-fail!))
                              [(conj pos (parse-expr c)) kws]))]
          (cond
            (sym? (peek-tok c) ",") (do (advance! c) (recur pos kws))
            (sym? (peek-tok c) ")") (recur pos kws)
            :else (e/parse-fail!)))))))

(defn- parse-simple
  "Parses one simple statement from the tokens of a logical line."
  [ts]
  (let [c (cursor ts)
        t (peek-tok c)
        kw (when (id? t) (nth t 1))]
    (case kw
      ("let" "set") (do (advance! c)
                        (let [name (ident! c)]
                          (eat-sym! c "=")
                          (let [x (parse-expr c)]
                            (expect-end! c)
                            {:op (keyword kw) :name name :expr x})))
      ("include" "abort" "default")
      (do (advance! c)
          (let [x (parse-expr c)] (expect-end! c) {:op (keyword kw) :expr x}))
      "phony" (do (advance! c)
                  (let [name (ident! c)]
                    (eat-sym! c "=")
                    (let [x (parse-expr c)] (expect-end! c) {:op :phony :name name :expr x})))
      "use" (do (advance! c) (parse-use c))
      (e/parse-fail!))))

(defn- parse-field
  "Parses one `step` field line."
  [ts]
  (let [c (cursor ts)
        t (peek-tok c)
        kw (when (id? t) (nth t 1))]
    (case kw
      ("out" "in" "after" "cost" "depfile")
      (do (advance! c)
          (let [x (parse-expr c)] (expect-end! c) {:f (keyword kw) :expr x}))
      "cmd" (do (advance! c)
                (let [name (any-ident! c)]
                  (eat-sym! c "(")
                  (let [args (parse-seq c ")")]
                    (expect-end! c)
                    {:f :cmd :name name :args args})))
      (e/parse-fail!))))

;; ------------------------------------------------------------ block headers

(defn- parse-rule-header
  "`rule NAME ( params ) {` with the trailing `{` already removed."
  [ts]
  (let [c (cursor ts)]
    (advance! c)
    (let [name (ident! c)]
      (eat-sym! c "(")
      (loop [params [] seen #{} defaulted? false]
        (cond
          (sym? (peek-tok c) ")")
          (do (advance! c) (expect-end! c) {:name name :params params})
          :else
          (let [p (ident! c)
                _ (when (seen p) (e/parse-fail!))
                dflt (when (sym? (peek-tok c) "=") (advance! c) (parse-expr c))
                _ (when (and defaulted? (nil? dflt)) (e/parse-fail!))
                params (conj params [p dflt])
                seen (conj seen p)
                defaulted? (or defaulted? (some? dflt))]
            (cond
              (sym? (peek-tok c) ",") (do (advance! c) (recur params seen defaulted?))
              (sym? (peek-tok c) ")") (recur params seen defaulted?)
              :else (e/parse-fail!))))))))

(defn- parse-each-header [ts]
  (let [c (cursor ts)]
    (advance! c)
    (let [a (ident! c)
          [idx name] (if (sym? (peek-tok c) ",")
                       (do (advance! c) [a (ident! c)])
                       [nil a])]
      (when (and idx (= idx name)) (e/parse-fail!))
      (when-not (word? (peek-tok c) "in") (e/parse-fail!))
      (advance! c)
      (let [x (parse-expr c)]
        (expect-end! c)
        {:idx idx :name name :expr x}))))

(defn- braces-outside?
  "True when a `{` or `}` token occurs in `ts` between indices [from, to)."
  [ts from to]
  (some (fn [t] (and (= :sym (nth t 0)) (#{"{" "}"} (nth t 1))))
        (subvec ts from to)))

;; ------------------------------------------------------------------ frames

(defn- new-frame [kind line extra]
  (merge {:kind kind :line line :body []} extra))

(defn- close-branch
  "Finishes the current branch of a `when` frame."
  [frame]
  (update frame :branches conj [(:cond frame) (:body frame)]))

(defn- frame->stmt [frame]
  (case (:kind frame)
    :when (if (:otherwise? frame)
            {:op :when :branches (:branches frame) :otherwise (:body frame)}
            {:op :when
             :branches (conj (:branches frame) [(:cond frame) (:body frame)])
             :otherwise nil})
    :each {:op :each :idx (:idx frame) :name (:name frame) :expr (:expr frame) :body (:body frame)}
    :rule {:op :rule :name (:name frame) :params (:params frame) :body (:body frame)}
    :step {:op :step :fields (:body frame)}))

(defn- add-stmt [stack stmt]
  (update stack (dec (count stack)) update :body conj stmt))

(defn- handle-terminator [stack ts line]
  (let [n (count ts)
        top (peek stack)]
    (when (= 1 (count stack)) (e/parse-fail!))
    (cond
      (= n 1)
      (let [stmt (frame->stmt top)]
        (add-stmt (pop stack) stmt))

      :else
      (let [second-tok (nth ts 1)]
        (when-not (and (= :id (nth second-tok 0))
                       (sym? (peek ts) "{")
                       (= :when (:kind top))
                       (not (:otherwise? top)))
          (e/parse-fail!))
        (when (braces-outside? ts 1 (dec n)) (e/parse-fail!))
        (case (nth second-tok 1)
          "elsewhen" (let [x (parse-whole-expr (subvec ts 2 (dec n)))]
                       (conj (pop stack)
                             (-> top close-branch
                                 (assoc :cond x :body [] :line line))))
          "otherwise" (do (when-not (= n 3) (e/parse-fail!))
                          (conj (pop stack)
                                (-> top close-branch
                                    (assoc :otherwise? true :body [] :line line))))
          (e/parse-fail!))))))

(defn- handle-header [stack ts line]
  (let [n (count ts)
        head (nth ts 0)
        body (subvec ts 0 (dec n))]
    (when (braces-outside? ts 0 (dec n)) (e/parse-fail!))
    (when (= :step (:kind (peek stack))) (e/parse-fail!))
    (conj stack
          (cond
            (word? head "step") (do (when-not (= n 2) (e/parse-fail!))
                                    (new-frame :step line {}))
            (word? head "when") (new-frame :when line
                                           {:branches [] :cond (parse-whole-expr (subvec body 1))})
            (word? head "each") (new-frame :each line (parse-each-header body))
            (word? head "rule") (new-frame :rule line (parse-rule-header body))
            :else (e/parse-fail!)))))

(defn- process-line [stack {:keys [line tokens]}]
  (try
    (let [first-tok (nth tokens 0)
          last-tok (peek tokens)]
      (cond
        (sym? first-tok "}")
        (if (and (= 1 (count tokens)))
          (handle-terminator stack tokens line)
          (do (when-not (sym? last-tok "{") (e/parse-fail!))
              (handle-terminator stack tokens line)))

        (sym? last-tok "{") (handle-header stack tokens line)

        :else
        (do (when (braces-outside? tokens 0 (count tokens)) (e/parse-fail!))
            (add-stmt stack
                      (if (= :step (:kind (peek stack)))
                        (parse-field tokens)
                        (parse-simple tokens))))))
    (catch clojure.lang.ExceptionInfo ex
      (if (e/parse-error? ex) (throw (e/with-line ex line)) (throw ex)))))

(defn parse-file
  "Lexes and parses build file `source` (a byte string).  Returns the vector of
  top-level statements.  Any syntax error is thrown as
  `E_PARSE <path>:<line>`; `path` is the file's workspace path."
  [path source]
  (try
    (let [lines (lex/lex-file source)
          stack (reduce process-line [(new-frame :root 0 {})] lines)]
      (when (> (count stack) 1)
        (throw (e/with-line (ex-info "parse error" {::e/parse true})
                 (:line (peek stack)))))
      (:body (nth stack 0)))
    (catch clojure.lang.ExceptionInfo ex
      (if (e/parse-error? ex)
        (e/fail! "E_PARSE" (str path ":" (e/parse-error-line ex)))
        (throw ex)))))
