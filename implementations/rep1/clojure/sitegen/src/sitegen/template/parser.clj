(ns sitegen.template.parser
  "Parses template source into a syntax tree.

  Expressions are vectors headed by a keyword:

      [:lit v] [:name s] [:attr e s] [:sub e e] [:call f positional keywords]
      [:filter e name args] [:defined e negated?] [:neg e] [:not e]
      [:bin op a b] [:and a b] [:or a b] [:cmp first [[op e] ...]] [:list es]

  Statements are maps with a `:t` key (`:text :print :if :for :set :macro
  :include :extends :block`).  A parsed template is
  `{:body [node ...] :blocks {name [node ...]}}`."
  (:require [sitegen.template.lexer :as lexer]
            [sitegen.template.filters :as filters]
            [sitegen.template.value :as v]
            [sitegen.mutable :refer [defmutable]])
  (:import (java.util HashSet LinkedHashMap)))

(set! *warn-on-reflection* true)

(defn- syntax-error! [msg] (v/error! :syntax msg))

(def ^:private keywords #{"and" "or" "not" "in" "is" "true" "false" "none"})

;; ---------------------------------------------------------------------------
;; Token cursor

(defmutable Cursor "cur-" [toks pos used-filters])

(defn- peek-tok
  ([c] (peek-tok c 0))
  ([c k] (let [toks (cur-toks c) i (+ (long (cur-pos c)) (long k))]
           (when (< i (count toks)) (nth toks i)))))

(defn- advance! [c] (cur-pos! c (inc (long (cur-pos c)))))

(defn- at-end? [c] (>= (long (cur-pos c)) (count (cur-toks c))))

(defn- op? [tok s] (and tok (= (nth tok 0) :op) (= (nth tok 1) s)))
(defn- kw? [tok s] (and tok (= (nth tok 0) :name) (= (nth tok 1) s)))

(defn- accept-op! [c s]
  (when (op? (peek-tok c) s) (advance! c) true))

(defn- expect-op! [c s]
  (when-not (accept-op! c s) (syntax-error! (str "expected " s))))

(defn- accept-kw! [c s]
  (when (kw? (peek-tok c) s) (advance! c) true))

(defn- expect-kw! [c s]
  (when-not (accept-kw! c s) (syntax-error! (str "expected " s))))

(defn- expect-name!
  "Consumes a name token that is not a reserved word; returns the name."
  [c]
  (let [tok (peek-tok c)]
    (if (and tok (= (nth tok 0) :name) (not (contains? keywords (nth tok 1))))
      (do (advance! c) (nth tok 1))
      (syntax-error! "expected a name"))))

(defn- expect-end! [c]
  (when-not (at-end? c) (syntax-error! "unexpected tokens at end of tag")))

;; ---------------------------------------------------------------------------
;; Expressions

(declare parse-expr)

(defn- parse-list-of
  "Parses comma-separated expressions up to the closing operator `close`
  (which is consumed).  A trailing comma is tolerated."
  [c close]
  (loop [acc []]
    (cond
      (accept-op! c close) acc
      :else (let [e (parse-expr c)
                  acc (conj acc e)]
              (cond
                (accept-op! c ",") (recur acc)
                (accept-op! c close) acc
                :else (syntax-error! (str "expected , or " close)))))))

(defn- parse-call-args
  "Parses call arguments up to `)`.  Returns [positional keywords]."
  [c]
  (loop [pos [] kws [] seen #{}]
    (if (accept-op! c ")")
      [pos kws]
      (let [t (peek-tok c)
            kw? (and t (= (nth t 0) :name) (op? (peek-tok c 1) "="))
            [pos kws seen]
            (if kw?
              (let [name (nth t 1)]
                (advance! c) (advance! c)
                (when (contains? seen name) (syntax-error! "duplicate keyword argument"))
                [pos (conj kws [name (parse-expr c)]) (conj seen name)])
              (do (when (seq kws) (syntax-error! "positional argument after keyword argument"))
                  [(conj pos (parse-expr c)) kws seen]))]
        (cond
          (accept-op! c ",") (recur pos kws seen)
          (accept-op! c ")") [pos kws]
          :else (syntax-error! "expected , or )"))))))

(defn- parse-primary [c]
  (let [tok (peek-tok c)]
    (when-not tok (syntax-error! "unexpected end of expression"))
    (let [[kind val] tok]
      (case kind
        (:int :float :string) (do (advance! c) [:lit val])
        :name (do (advance! c)
                  (case val
                    "true" [:lit true]
                    "false" [:lit false]
                    "none" [:lit nil]
                    (if (contains? keywords val)
                      (syntax-error! (str "unexpected keyword " val))
                      [:name val])))
        :op (case val
              "(" (do (advance! c)
                      (let [e (parse-expr c)]
                        (expect-op! c ")")
                        e))
              "[" (do (advance! c) [:list (parse-list-of c "]")])
              (syntax-error! (str "unexpected " val)))))))

(defn- parse-postfix [c]
  (loop [e (parse-primary c)]
    (cond
      (accept-op! c ".")
      (let [tok (peek-tok c)]
        (if (and tok (= (nth tok 0) :name))
          (do (advance! c) (recur [:attr e (nth tok 1)]))
          (syntax-error! "expected a member name")))

      (accept-op! c "[")
      (let [idx (parse-expr c)]
        (expect-op! c "]")
        (recur [:sub e idx]))

      (accept-op! c "(")
      (let [[pos kws] (parse-call-args c)]
        (recur [:call e pos kws]))

      :else e)))

(defn- parse-unary [c]
  (if (accept-op! c "-")
    [:neg (parse-unary c)]
    (parse-postfix c)))

(defn- parse-filtered [c]
  (loop [e (parse-unary c)]
    (cond
      (accept-op! c "|")
      (let [tok (peek-tok c)]
        (when-not (and tok (= (nth tok 0) :name)) (syntax-error! "expected a filter name"))
        (advance! c)
        (let [name (nth tok 1)
              args (if (accept-op! c "(") (parse-list-of c ")") [])]
          (.add ^HashSet (cur-used-filters c) name)
          (recur [:filter e name args])))

      (accept-kw! c "is")
      (let [negated? (boolean (accept-kw! c "not"))]
        (expect-kw! c "defined")
        (recur [:defined e negated?]))

      :else e)))

(defn- left-assoc
  "Builds a left-associative binary level: `ops` maps operator text to the
  operator keyword, `sub` parses the operands."
  [c sub ops]
  (loop [l (sub c)]
    (let [tok (peek-tok c)
          op (when (and tok (= (nth tok 0) :op)) (get ops (nth tok 1)))]
      (if op
        (do (advance! c) (recur [:bin op l (sub c)]))
        l))))

(defn- parse-power [c] (left-assoc c parse-filtered {"**" :pow}))
(defn- parse-term [c] (left-assoc c parse-power {"*" :mul "/" :div "//" :floordiv "%" :mod}))
(defn- parse-concat [c] (left-assoc c parse-term {"~" :concat}))
(defn- parse-additive [c] (left-assoc c parse-concat {"+" :add "-" :sub}))

(defn- accept-cmp-op! [c]
  (let [tok (peek-tok c)]
    (cond
      (and tok (= (nth tok 0) :op) (contains? #{"==" "!=" "<" "<=" ">" ">="} (nth tok 1)))
      (do (advance! c) (nth tok 1))

      (kw? tok "in") (do (advance! c) "in")

      (and (kw? tok "not") (kw? (peek-tok c 1) "in"))
      (do (advance! c) (advance! c) "not in")

      :else nil)))

(defn- parse-compare [c]
  (let [first-operand (parse-additive c)]
    (loop [ops []]
      (if-let [op (accept-cmp-op! c)]
        (recur (conj ops [op (parse-additive c)]))
        (if (empty? ops) first-operand [:cmp first-operand ops])))))

(defn- parse-not [c]
  (if (accept-kw! c "not")
    [:not (parse-not c)]
    (parse-compare c)))

(defn- parse-and [c]
  (loop [l (parse-not c)]
    (if (accept-kw! c "and") (recur [:and l (parse-not c)]) l)))

(defn- parse-or [c]
  (loop [l (parse-and c)]
    (if (accept-kw! c "or") (recur [:or l (parse-and c)]) l)))

(defn- parse-expr [c] (parse-or c))

(defn- complete-expr
  "Parses `toks` as one whole expression."
  [toks fs]
  (let [c (->Cursor toks 0 fs)
        e (parse-expr c)]
    (expect-end! c)
    e))

;; ---------------------------------------------------------------------------
;; Statements

(defmutable Parser "ps-" [items idx blocks filters depth extended])

(declare parse-body)

(defn- sub-body
  "Parses a nested body one level deeper; returns [nodes terminator-tokens]."
  [ps terms]
  (ps-depth! ps (inc (long (ps-depth ps))))
  (let [r (parse-body ps terms)]
    (ps-depth! ps (dec (long (ps-depth ps))))
    r))

(defn- no-more! [toks]
  (when (seq toks) (syntax-error! "unexpected tokens at end of tag")))

(defn- parse-if [ps toks]
  (let [fs (ps-filters ps)]
    (loop [cond-expr (complete-expr toks fs)
           branches []]
      (let [[body term] (sub-body ps #{"elif" "else" "endif"})
            branches (conj branches [cond-expr body])
            rest-toks (subvec term 1)]
        (case (nth (first term) 1)
          "elif" (recur (complete-expr rest-toks fs) branches)
          "else" (do (no-more! rest-toks)
                     (let [[else-body term2] (sub-body ps #{"endif"})]
                       (no-more! (subvec term2 1))
                       {:t :if :branches branches :else else-body}))
          "endif" (do (no-more! rest-toks)
                      {:t :if :branches branches :else nil}))))))

(defn- parse-for [ps toks]
  (let [c (->Cursor toks 0 (ps-filters ps))
        var (expect-name! c)
        _ (expect-kw! c "in")
        iter (parse-expr c)
        _ (expect-end! c)
        [body term] (sub-body ps #{"else" "endfor"})]
    (if (= "else" (nth (first term) 1))
      (let [_ (no-more! (subvec term 1))
            [else-body term2] (sub-body ps #{"endfor"})]
        (no-more! (subvec term2 1))
        {:t :for :var var :iter iter :body body :else else-body})
      (do (no-more! (subvec term 1))
          {:t :for :var var :iter iter :body body :else nil}))))

(defn- parse-set [ps toks]
  (let [c (->Cursor toks 0 (ps-filters ps))
        name (expect-name! c)]
    (expect-op! c "=")
    (let [e (parse-expr c)]
      (expect-end! c)
      {:t :set :name name :e e})))

(defn- parse-macro [ps toks]
  (let [c (->Cursor toks 0 (ps-filters ps))
        name (expect-name! c)
        _ (expect-op! c "(")
        params (loop [params []]
                 (if (accept-op! c ")")
                   params
                   (let [p (expect-name! c)
                         _ (when (some #(= p (first %)) params) (syntax-error! "duplicate parameter"))
                         default (when (accept-op! c "=") (parse-expr c))
                         params (conj params [p default])]
                     (cond
                       (accept-op! c ",") (recur params)
                       (accept-op! c ")") params
                       :else (syntax-error! "expected , or )")))))
        _ (expect-end! c)
        [body term] (sub-body ps #{"endmacro"})]
    (no-more! (subvec term 1))
    {:t :macro :name name :params params :body body}))

(defn- parse-block [ps toks]
  (let [c (->Cursor toks 0 (ps-filters ps))
        name (expect-name! c)
        _ (expect-end! c)
        ^LinkedHashMap blocks (ps-blocks ps)
        _ (when (.containsKey blocks name) (syntax-error! (str "duplicate block " name)))
        _ (.put blocks name nil)
        [body term] (sub-body ps #{"endblock"})
        rest-toks (subvec term 1)]
    (when (seq rest-toks)
      (when-not (and (= 1 (count rest-toks)) (= [:name name] (first rest-toks)))
        (syntax-error! "endblock name does not match")))
    (.put blocks name body)
    {:t :block :name name}))

(defn- parse-statement [ps kw toks]
  (let [rest-toks (subvec toks 1)]
    (case kw
      "if" (parse-if ps rest-toks)
      "for" (parse-for ps rest-toks)
      "set" (parse-set ps rest-toks)
      "macro" (parse-macro ps rest-toks)
      "block" (parse-block ps rest-toks)
      "include" {:t :include :e (complete-expr rest-toks (ps-filters ps))}
      "extends" (do (when (or (pos? (long (ps-depth ps))) (ps-extended ps))
                      (syntax-error! "misplaced extends"))
                    (ps-extended! ps true)
                    {:t :extends :e (complete-expr rest-toks (ps-filters ps))})
      (syntax-error! (str "unknown statement " kw)))))

(defn- parse-body
  "Parses items until a statement whose keyword is in `terms` (or the end of
  the template when `terms` is nil).  Returns [nodes terminator-tokens]."
  [ps terms]
  (let [items (ps-items ps)]
    (loop [nodes (transient [])]
      (let [i (long (ps-idx ps))]
        (if (>= i (count items))
          (if terms
            (syntax-error! "unexpected end of template")
            [(persistent! nodes) nil])
          (let [[kind data] (nth items i)]
            (ps-idx! ps (inc i))
            (case kind
              :text (recur (conj! nodes {:t :text :s data}))
              :print (recur (conj! nodes {:t :print :e (complete-expr data (ps-filters ps))}))
              :stmt (let [tok (first data)]
                      (when-not (and tok (= (nth tok 0) :name))
                        (syntax-error! "empty or malformed statement"))
                      (let [kw (nth tok 1)]
                        (if (contains? terms kw)
                          [(persistent! nodes) data]
                          (recur (conj! nodes (parse-statement ps kw data)))))))))))))

(defn parse-template
  "Parses the template source `source`.  Throws a `syntax` error when it is
  malformed and then a `filter` error when it uses an unknown filter."
  [^String source]
  (let [ps (->Parser (lexer/tokenize source) 0 (LinkedHashMap.) (HashSet.) 0 false)
        [body _] (parse-body ps nil)]
    (doseq [f (ps-filters ps)]
      (when-not (filters/known? f)
        (v/error! :filter (str "unknown filter " f))))
    {:body body :blocks (ps-blocks ps)}))
