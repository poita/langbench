(ns template.parser
  "Recursive-descent parser: template source -> syntax tree.

  [[parse]] lexes and parses one template and then checks every filter name it
  uses, so a successfully parsed template is fully loaded. It returns
  `{:body [node ...], :blocks {name body}}`.

  Expression nodes:

      [:lit v]  [:name n]  [:list [e ...]]  [:get obj key]
      [:call callee [arg ...] [[kw e] ...]]  [:filter e name [arg ...]]
      [:defined e negated?]  [:neg e]  [:not e]  [:and a b]  [:or a b]
      [:binop op a b]  [:compare first [[op e] ...]]

  Statement nodes:

      [:text s]  [:print e]  [:if [[cond body] ...] else-body-or-nil]
      [:for name iter body else-body-or-nil]  [:set name e]
      [:macro name [[param default-or-nil] ...] body]
      [:include e]  [:extends e]  [:block name]"
  (:require [template.errors :as err]
            [template.filters :as filters]
            [template.lexer :as lexer]))

(set! *warn-on-reflection* true)

(defn- syntax! [msg] (err/fail :syntax msg))

(def ^:private keywords #{"and" "or" "not" "in" "is" "true" "false" "none"})

;; ---------------------------------------------------------------------------
;; Expression parser state: a token vector, a cursor and the filter-name set.

(def ^:private eof-token [:eof nil])

(defn- make-parser [toks start filter-names]
  {:toks toks :pos (doto (long-array 1) (aset 0 (long start))) :filters filter-names})

(defn- peek-at [p ^long k]
  (let [toks (:toks p) i (+ (aget ^longs (:pos p) 0) k)]
    (if (< i (count toks)) (nth toks i) eof-token)))

(defn- peek-tok [p] (peek-at p 0))

(defn- adv! [p]
  (aset ^longs (:pos p) 0 (inc (aget ^longs (:pos p) 0))))

(defn- op-tok? [tok s] (and (identical? (nth tok 0) :op) (= (nth tok 1) s)))
(defn- kw-tok? [tok s] (and (identical? (nth tok 0) :name) (= (nth tok 1) s)))

(defn- op? [p s] (op-tok? (peek-tok p) s))
(defn- kw? [p s] (kw-tok? (peek-tok p) s))

(defn- expect-op! [p s]
  (if (op? p s) (adv! p) (syntax! (str "expected '" s "'"))))

(defn- expect-eof! [p]
  (when-not (identical? (nth (peek-tok p) 0) :eof)
    (syntax! "unexpected token at end of tag")))

(declare parse-expression)

(defn- parse-expr-list
  "Comma-separated expressions up to `close` (already past the opener)."
  [p close]
  (if (op? p close)
    (do (adv! p) [])
    (loop [out []]
      (let [out (conj out (parse-expression p))]
        (cond
          (op? p ",") (do (adv! p) (recur out))
          (op? p close) (do (adv! p) out)
          :else (syntax! (str "expected ',' or '" close "'")))))))

(defn- parse-call-args
  "Call arguments up to `)`. Returns [positional [[kw expr] ...]]."
  [p]
  (if (op? p ")")
    (do (adv! p) [[] []])
    (loop [args [] kwargs [] seen #{}]
      (let [tok (peek-tok p)
            kwarg? (and (identical? (nth tok 0) :name) (op-tok? (peek-at p 1) "="))
            [args kwargs seen]
            (if kwarg?
              (let [n (nth tok 1)]
                (when (or (contains? seen n) (contains? keywords n))
                  (syntax! "bad keyword argument"))
                (adv! p) (adv! p)
                [args (conj kwargs [n (parse-expression p)]) (conj seen n)])
              (do (when (seq kwargs) (syntax! "positional argument after keyword argument"))
                  [(conj args (parse-expression p)) kwargs seen]))]
        (cond
          (op? p ",") (do (adv! p) (recur args kwargs seen))
          (op? p ")") (do (adv! p) [args kwargs])
          :else (syntax! "expected ',' or ')'"))))))

(defn- parse-primary [p]
  (let [tok (peek-tok p) t (nth tok 0) v (nth tok 1)]
    (case t
      (:int :float :str) (do (adv! p) [:lit v])
      :name (cond
              (= v "true") (do (adv! p) [:lit true])
              (= v "false") (do (adv! p) [:lit false])
              (= v "none") (do (adv! p) [:lit nil])
              (contains? keywords v) (syntax! (str "unexpected keyword " v))
              :else (do (adv! p) [:name v]))
      :op (cond
            (= v "[") (do (adv! p) [:list (parse-expr-list p "]")])
            (= v "(") (do (adv! p)
                          (let [e (parse-expression p)]
                            (expect-op! p ")")
                            e))
            :else (syntax! (str "unexpected '" v "'")))
      (syntax! "unexpected end of expression"))))

(defn- parse-postfix [p]
  (loop [e (parse-primary p)]
    (cond
      (op? p ".") (do (adv! p)
                      (let [tok (peek-tok p)]
                        (when-not (identical? (nth tok 0) :name) (syntax! "expected attribute name"))
                        (adv! p)
                        (recur [:get e [:lit (nth tok 1)]])))
      (op? p "[") (do (adv! p)
                      (let [k (parse-expression p)]
                        (expect-op! p "]")
                        (recur [:get e k])))
      (op? p "(") (do (adv! p)
                      (let [[args kwargs] (parse-call-args p)]
                        (recur [:call e args kwargs])))
      :else e)))

(defn- parse-unary [p]
  (if (op? p "-")
    (do (adv! p) [:neg (parse-unary p)])
    (parse-postfix p)))

(defn- parse-filtered [p]
  (loop [e (parse-unary p)]
    (cond
      (op? p "|")
      (do (adv! p)
          (let [tok (peek-tok p)]
            (when-not (identical? (nth tok 0) :name) (syntax! "expected filter name"))
            (adv! p)
            (let [fname (nth tok 1)
                  args (if (op? p "(") (do (adv! p) (parse-expr-list p ")")) [])]
              (vswap! (:filters p) conj fname)
              (recur [:filter e fname args]))))

      (kw? p "is")
      (do (adv! p)
          (let [negated? (when (kw? p "not") (adv! p) true)]
            (when-not (kw? p "defined") (syntax! "unknown test"))
            (adv! p)
            (recur [:defined e (boolean negated?)])))

      :else e)))

(defn- parse-left-assoc
  "Parse `operand (op operand)*`; `ops` maps operator strings to keywords."
  [p operand ops]
  (loop [l (operand p)]
    (let [tok (peek-tok p)
          op (when (identical? (nth tok 0) :op) (get ops (nth tok 1)))]
      (if op
        (do (adv! p) (recur [:binop op l (operand p)]))
        l))))

(defn- parse-power [p] (parse-left-assoc p parse-filtered {"**" :pow}))
(defn- parse-term [p]
  (parse-left-assoc p parse-power {"*" :mul "/" :div "//" :floordiv "%" :mod}))
(defn- parse-concat [p] (parse-left-assoc p parse-term {"~" :concat}))
(defn- parse-additive [p] (parse-left-assoc p parse-concat {"+" :add "-" :sub}))

(def ^:private cmp-ops {"==" :eq "!=" :ne "<" :lt "<=" :le ">" :gt ">=" :ge})

(defn- peek-cmp-op
  "Consume and return the comparison operator at the cursor, or nil."
  [p]
  (let [tok (peek-tok p)]
    (cond
      (identical? (nth tok 0) :op)
      (when-let [op (get cmp-ops (nth tok 1))] (adv! p) op)

      (kw-tok? tok "in") (do (adv! p) :in)

      (and (kw-tok? tok "not") (kw-tok? (peek-at p 1) "in"))
      (do (adv! p) (adv! p) :not-in))))

(defn- parse-compare [p]
  (let [e (parse-additive p)]
    (loop [rest []]
      (if-let [op (peek-cmp-op p)]
        (recur (conj rest [op (parse-additive p)]))
        (if (empty? rest) e [:compare e rest])))))

(defn- parse-not [p]
  (if (kw? p "not")
    (do (adv! p) [:not (parse-not p)])
    (parse-compare p)))

(defn- parse-and [p]
  (loop [l (parse-not p)]
    (if (kw? p "and") (do (adv! p) (recur [:and l (parse-not p)])) l)))

(defn- parse-or [p]
  (loop [l (parse-and p)]
    (if (kw? p "or") (do (adv! p) (recur [:or l (parse-and p)])) l)))

(defn- parse-expression [p] (parse-or p))

(defn- parse-tag-expression
  "Parse tokens `toks` from index `start` as exactly one expression."
  [toks start filter-names]
  (let [p (make-parser toks start filter-names)
        e (parse-expression p)]
    (expect-eof! p)
    e))

;; ---------------------------------------------------------------------------
;; Statement parser state

(defn- tok-name
  "The identifier at index `i` of `toks`, which must be a non-keyword name."
  [toks i]
  (let [tok (when (< i (count toks)) (nth toks i))]
    (when-not (and tok (identical? (nth tok 0) :name) (not (contains? keywords (nth tok 1))))
      (syntax! "expected a name"))
    (nth tok 1)))

(defn- cur [st] (let [items (:items st) i (aget ^longs (:i st) 0)]
                  (when (< i (count items)) (nth items i))))

(defn- advance! [st] (aset ^longs (:i st) 0 (inc (aget ^longs (:i st) 0))))

(defn- stmt-keyword [toks]
  (let [tok (when (seq toks) (nth toks 0))]
    (when-not (and tok (identical? (nth tok 0) :name)) (syntax! "empty or malformed statement"))
    (nth tok 1)))

(defn- next-stmt!
  "Consume the next item, which must be a statement; returns [keyword tokens]."
  [st]
  (let [item (cur st)]
    (when-not (and item (identical? (nth item 0) :stmt)) (syntax! "missing end tag"))
    (advance! st)
    [(stmt-keyword (nth item 1)) (nth item 1)]))

(defn- expect-bare! [toks]
  (when-not (== 1 (count toks)) (syntax! "unexpected tokens after statement keyword")))

(declare parse-stmt)

(defn- parse-body
  "Parse items until a statement whose keyword is in `terminators` (not
  consumed) or the end of the template."
  [st terminators depth]
  (loop [nodes (transient [])]
    (let [item (cur st)]
      (if (nil? item)
        (persistent! nodes)
        (case (nth item 0)
          :text (do (advance! st) (recur (conj! nodes [:text (nth item 1)])))
          :print (do (advance! st)
                     (recur (conj! nodes [:print (parse-tag-expression (nth item 1) 0 (:filters st))])))
          :stmt (let [toks (nth item 1) kw (stmt-keyword toks)]
                  (if (contains? terminators kw)
                    (persistent! nodes)
                    (do (advance! st)
                        (recur (conj! nodes (parse-stmt st kw toks depth)))))))))))

(defn- parse-if [st toks depth]
  (let [fs (:filters st)
        body-depth (inc depth)
        c (parse-tag-expression toks 1 fs)
        b (parse-body st #{"elif" "else" "endif"} body-depth)]
    (loop [branches [[c b]]]
      (let [[kw toks] (next-stmt! st)]
        (case kw
          "elif" (let [c (parse-tag-expression toks 1 fs)
                       b (parse-body st #{"elif" "else" "endif"} body-depth)]
                   (recur (conj branches [c b])))
          "else" (do (expect-bare! toks)
                     (let [b (parse-body st #{"endif"} body-depth)
                           [_ toks] (next-stmt! st)]
                       (expect-bare! toks)
                       [:if branches b]))
          "endif" (do (expect-bare! toks) [:if branches nil]))))))

(defn- parse-for [st toks depth]
  (let [n (tok-name toks 1)
        _ (when-not (kw-tok? (if (> (count toks) 2) (nth toks 2) eof-token) "in")
            (syntax! "expected 'in'"))
        iter (parse-tag-expression toks 3 (:filters st))
        body (parse-body st #{"else" "endfor"} (inc depth))
        [kw toks2] (next-stmt! st)]
    (expect-bare! toks2)
    (if (= kw "else")
      (let [eb (parse-body st #{"endfor"} (inc depth))
            [_ toks3] (next-stmt! st)]
        (expect-bare! toks3)
        [:for n iter body eb])
      [:for n iter body nil])))

(defn- parse-macro [st toks depth]
  (let [name (tok-name toks 1)
        p (make-parser toks 2 (:filters st))
        _ (expect-op! p "(")
        params (if (op? p ")")
                 (do (adv! p) [])
                 (loop [params [] seen #{}]
                   (let [tok (peek-tok p)
                         _ (when-not (and (identical? (nth tok 0) :name) (not (contains? keywords (nth tok 1))))
                             (syntax! "expected parameter name"))
                         pn (nth tok 1)
                         _ (when (contains? seen pn) (syntax! "duplicate parameter"))
                         _ (adv! p)
                         default (when (op? p "=") (adv! p) (parse-expression p))
                         params (conj params [pn default])
                         seen (conj seen pn)]
                     (cond
                       (op? p ",") (do (adv! p) (recur params seen))
                       (op? p ")") (do (adv! p) params)
                       :else (syntax! "expected ',' or ')'")))))
        _ (expect-eof! p)
        body (parse-body st #{"endmacro"} (inc depth))
        [_ toks2] (next-stmt! st)]
    (expect-bare! toks2)
    [:macro name params body]))

(defn- parse-block [st toks depth]
  (let [name (tok-name toks 1)]
    (when-not (== 2 (count toks)) (syntax! "unexpected tokens after block name"))
    (when (contains? @(:blocks st) name) (syntax! "duplicate block name"))
    (vswap! (:blocks st) assoc name nil)
    (let [body (parse-body st #{"endblock"} (inc depth))
          [_ toks2] (next-stmt! st)]
      (case (count toks2)
        1 nil
        2 (when-not (= (nth toks2 1) [:name name]) (syntax! "endblock name mismatch"))
        (syntax! "unexpected tokens after endblock"))
      (vswap! (:blocks st) assoc name body)
      [:block name])))

(defn- parse-stmt [st kw toks depth]
  (let [fs (:filters st)]
    (case kw
      "if" (parse-if st toks depth)
      "for" (parse-for st toks depth)
      "set" (let [n (tok-name toks 1)]
              (when-not (and (> (count toks) 2) (op-tok? (nth toks 2) "="))
                (syntax! "expected '=' in set"))
              [:set n (parse-tag-expression toks 3 fs)])
      "macro" (parse-macro st toks depth)
      "include" [:include (parse-tag-expression toks 1 fs)]
      "extends" (do (when (pos? depth) (syntax! "extends must be at the top level"))
                    (when @(:extends st) (syntax! "extends used twice"))
                    (vreset! (:extends st) true)
                    [:extends (parse-tag-expression toks 1 fs)])
      "block" (parse-block st toks depth)
      (syntax! (str "unknown statement: " kw)))))

(defn parse
  "Lex, parse and filter-check template source `src`. Throws a `:syntax` or
  `:filter` error (in that order of precedence)."
  [^String src]
  (let [items (lexer/lex src)
        st {:items items :i (long-array 1) :filters (volatile! #{})
            :blocks (volatile! {}) :extends (volatile! false)}
        body (parse-body st #{} 0)]
    (when (cur st) (syntax! "unexpected statement"))
    (doseq [f @(:filters st)]
      (when-not (filters/known? f) (err/fail :filter (str "unknown filter: " f))))
    {:body body :blocks @(:blocks st)}))
