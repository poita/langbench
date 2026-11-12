(ns jq.parser
  "Recursive-descent parser from filter text to a syntax tree.

  The tree is made of vectors headed by a keyword:

  ```
  [:identity]                    [:lit v]                [:var name]
  [:index target key opt?]       [:slice target from to opt?]
  [:iterate target opt?]         [:try node]             [:neg node]
  [:binop op a b]                [:and a b]              [:or a b]
  [:comma a b]                   [:pipe a b]             [:array node-or-nil]
  [:object [[key-node val-node] ...]]
  [:if cond then else]           [:bind source name body]
  [:reduce source name init update]
  [:call name [arg ...]]
  ```"
  (:require [jq.lexer :as lexer]))

(set! *warn-on-reflection* true)

(def ^:private keywords
  #{"if" "then" "elif" "else" "end" "as" "reduce" "and" "or"})

(defn- syntax-error [msg]
  (throw (ex-info (str "jq syntax error: " msg) {:type ::syntax-error})))

(defn parse
  "Parses the filter text `src` into a syntax tree. Throws `ex-info` with
  `:type` `:jq.lexer/syntax-error` or `:jq.parser/syntax-error` on bad input."
  [^String src]
  (let [toks (lexer/tokenize src)
        n (count toks)
        pos (volatile! 0)]
    (letfn [(peek-tok [] (if (< @pos n) (nth toks @pos) [:eof nil]))
            (advance! [] (let [t (peek-tok)] (vswap! pos inc) t))
            (punct? [s] (let [[t v] (peek-tok)] (and (= t :punct) (= v s))))
            (kw? [s] (let [[t v] (peek-tok)] (and (= t :ident) (= v s))))
            (accept-punct [s] (when (punct? s) (advance!) true))
            (expect-punct [s]
              (when-not (accept-punct s)
                (syntax-error (str "expected '" s "' but found " (pr-str (peek-tok))))))
            (expect-kw [s]
              (if (kw? s) (advance!) (syntax-error (str "expected '" s "' but found " (pr-str (peek-tok))))))
            (expect-var []
              (let [[t v] (advance!)]
                (if (= t :var) v (syntax-error "expected a variable"))))

            (parse-pipe []
              (let [lhs (parse-comma)]
                (if (accept-punct "|")
                  [:pipe lhs (parse-pipe)]
                  lhs)))

            (parse-comma []
              (loop [lhs (parse-or)]
                (if (accept-punct ",")
                  (recur [:comma lhs (parse-or)])
                  lhs)))

            (parse-or []
              (loop [lhs (parse-and)]
                (if (kw? "or")
                  (do (advance!) (recur [:or lhs (parse-and)]))
                  lhs)))

            (parse-and []
              (loop [lhs (parse-cmp)]
                (if (kw? "and")
                  (do (advance!) (recur [:and lhs (parse-cmp)]))
                  lhs)))

            (parse-cmp []
              (let [lhs (parse-add)
                    [t v] (peek-tok)]
                (if (and (= t :punct) (#{"==" "!=" "<" "<=" ">" ">="} v))
                  (do (advance!) [:binop (keyword v) lhs (parse-add)])
                  lhs)))

            (parse-add []
              (loop [lhs (parse-mul)]
                (let [[t v] (peek-tok)]
                  (if (and (= t :punct) (#{"+" "-"} v))
                    (do (advance!) (recur [:binop (keyword v) lhs (parse-mul)]))
                    lhs))))

            (parse-mul []
              (loop [lhs (parse-unary)]
                (let [[t v] (peek-tok)]
                  (if (and (= t :punct) (#{"*" "/" "%"} v))
                    (do (advance!) (recur [:binop (keyword v) lhs (parse-unary)]))
                    lhs))))

            (parse-unary []
              (if (accept-punct "-")
                [:neg (parse-unary)]
                (parse-postfix true)))

            ;; postfix := primary { suffix | "?" } ; with allow-as, a trailing
            ;; `as $x | body` turns the term into a binding.
            (parse-postfix [allow-as]
              (loop [suffix? (when (= :field (first (peek-tok))) :suffix)   ; `.a` is a field suffix of `.`
                     node (parse-primary)]
                (let [[t v] (peek-tok)]
                  (cond
                    (= t :field)
                    (do (advance!) (recur :suffix [:index node [:lit v] false]))

                    (and (= t :punct) (= v "["))
                    (do (advance!) (recur :suffix (parse-bracket node)))

                    (and (= t :punct) (= v "?"))
                    (do (advance!)
                        (recur nil
                               (if (and suffix? (#{:index :slice :iterate} (node 0)))
                                 (assoc node (dec (count node)) true)
                                 [:try node])))

                    (and allow-as (= t :ident) (= v "as"))
                    (do (advance!)
                        (let [name (expect-var)]
                          (expect-punct "|")
                          [:bind node name (parse-pipe)]))

                    :else node))))

            (parse-bracket [target]
              (cond
                (accept-punct "]") [:iterate target false]
                (accept-punct ":") (let [to (parse-pipe)]
                                     (expect-punct "]")
                                     [:slice target nil to false])
                :else (let [e (parse-pipe)]
                        (cond
                          (accept-punct "]") [:index target e false]
                          (accept-punct ":") (let [to (when-not (punct? "]") (parse-pipe))]
                                               (expect-punct "]")
                                               [:slice target e to false])
                          :else (syntax-error "expected ] or :")))))

            (parse-primary []
              (let [[t v] (advance!)]
                (case t
                  :num [:lit v]
                  :str [:lit v]
                  :field [:index [:identity] [:lit v] false]
                  :dot [:identity]
                  :var [:var v]
                  :punct (case v
                           "(" (let [e (parse-pipe)] (expect-punct ")") e)
                           "[" (if (accept-punct "]")
                                 [:array nil]
                                 (let [e (parse-pipe)] (expect-punct "]") [:array e]))
                           "{" (parse-object)
                           (syntax-error (str "unexpected '" v "'")))
                  :ident (case v
                           "true" [:lit true]
                           "false" [:lit false]
                           "null" [:lit nil]
                           "if" (parse-if)
                           "reduce" (parse-reduce)
                           (if (keywords v)
                             (syntax-error (str "unexpected keyword " v))
                             (parse-call v)))
                  (syntax-error "unexpected end of input"))))

            (parse-call [name]
              (if (accept-punct "(")
                (loop [args [(parse-pipe)]]
                  (if (accept-punct ";")
                    (recur (conj args (parse-pipe)))
                    (do (expect-punct ")") [:call name args])))
                [:call name []]))

            (parse-if []
              (let [c (parse-pipe)
                    _ (expect-kw "then")
                    then (parse-pipe)]
                (cond
                  (kw? "elif") (do (advance!) [:if c then (parse-if-rest)])
                  (kw? "else") (do (advance!)
                                   (let [e (parse-pipe)] (expect-kw "end") [:if c then e]))
                  :else (do (expect-kw "end") [:if c then [:identity]]))))

            ;; after "elif": same shape as after "if"
            (parse-if-rest [] (parse-if))

            (parse-reduce []
              (let [src (parse-postfix false)]
                (expect-kw "as")
                (let [name (expect-var)]
                  (expect-punct "(")
                  (let [init (parse-pipe)]
                    (expect-punct ";")
                    (let [update (parse-pipe)]
                      (expect-punct ")")
                      [:reduce src name init update])))))

            (parse-object []
              (if (accept-punct "}")
                [:object []]
                (loop [entries []]
                  (let [entries (conj entries (parse-entry))]
                    (cond (accept-punct ",") (recur entries)
                          :else (do (expect-punct "}") [:object entries]))))))

            (parse-entry []
              (let [[t v] (advance!)]
                (case t
                  :var [[:lit v] [:var v]]
                  :str (if (accept-punct ":") [[:lit v] (parse-objval)]
                           [[:lit v] [:index [:identity] [:lit v] false]])
                  :ident (if (accept-punct ":") [[:lit v] (parse-objval)]
                             [[:lit v] [:index [:identity] [:lit v] false]])
                  :punct (if (= v "(")
                           (let [k (parse-pipe)]
                             (expect-punct ")")
                             (expect-punct ":")
                             [k (parse-objval)])
                           (syntax-error (str "bad object key '" v "'")))
                  (syntax-error "bad object entry"))))

            (parse-objval []
              (loop [lhs (parse-objterm)]
                (if (accept-punct "|")
                  (recur [:pipe lhs (parse-objterm)])
                  lhs)))

            (parse-objterm []
              (if (accept-punct "-")
                [:neg (parse-objterm)]
                (parse-postfix false)))]
      (let [tree (parse-pipe)]
        (when (< @pos n)
          (syntax-error (str "unexpected " (pr-str (peek-tok)))))
        tree))))
