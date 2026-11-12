(ns spreadsheet.parser
  "Parses cell content (the text after `set <CELL> `) into a syntax tree.

  Syntax tree nodes are vectors headed by a keyword:

      [:num d]                  [:str s]            [:err kw]
      [:ref id]                 [:neg x]
      [:arith op l r]           op is :+ :- :* or :/
      [:cat l r]
      [:cmp op l r]             op is :eq :ne :lt :gt :le :ge
      [:if c a b]
      [:agg fn args]            fn is :sum :min :max :avg or :count; each arg
                                is a node or [:range row1 col1 row2 col2]

  Parentheses leave no trace in the tree. A formula containing an invalid
  reference parses to `[:err :error/ref]`."
  (:require [spreadsheet.cell :as cell]))

;;; Tokenizer

(defn- digit? [c] (and (>= (int c) 48) (<= (int c) 57)))
(defn- upper? [c] (and (>= (int c) 65) (<= (int c) 90)))

(defn- tokenize
  "Splits formula text (without the leading `=`) into a vector of tokens:
  [:num d], [:str s], [:ref text], [:name text] or an operator keyword."
  [^String s]
  (let [n (.length s)]
    (loop [i 0 out (transient [])]
      (if (>= i n)
        (persistent! out)
        (let [c (.charAt s i)
              nxt (when (< (inc i) n) (.charAt s (inc i)))]
          (cond
            (= c \space) (recur (inc i) out)

            (digit? c)
            (let [j (loop [j (long i)] (if (and (< j n) (digit? (.charAt s j))) (recur (inc j)) j))
                  j (if (and (< (inc j) n) (= \. (.charAt s j)) (digit? (.charAt s (inc j))))
                      (loop [j (long (inc j))] (if (and (< j n) (digit? (.charAt s j))) (recur (inc j)) j))
                      j)]
              (recur (long j) (conj! out [:num (Double/parseDouble (subs s i j))])))

            (upper? c)
            (let [j (loop [j (long i)] (if (and (< j n) (upper? (.charAt s j))) (recur (inc j)) j))
                  k (loop [k (long j)] (if (and (< k n) (digit? (.charAt s k))) (recur (inc k)) k))]
              (if (> k j)
                (recur (long k) (conj! out [:ref (subs s i k)]))
                (recur (long j) (conj! out [:name (subs s i j)]))))

            (= c \")
            (let [j (.indexOf s "\"" (int (inc i)))]
              (recur (long (inc j)) (conj! out [:str (subs s (inc i) j)])))

            (and (= c \<) (= nxt \>)) (recur (+ i 2) (conj! out :ne))
            (and (= c \<) (= nxt \=)) (recur (+ i 2) (conj! out :le))
            (and (= c \>) (= nxt \=)) (recur (+ i 2) (conj! out :ge))
            :else
            (recur (inc i)
                   (conj! out (case c
                                \< :lt \> :gt \= :eq \& :cat \+ :+ \- :- \* :* \/ :/
                                \( :lparen \) :rparen \, :comma \: :colon)))))))))

;;; Parser

(def ^:private agg-fns
  {"SUM" :sum "MIN" :min "MAX" :max "AVG" :avg "COUNT" :count})

(def ^:private cmp-ops #{:eq :ne :lt :gt :le :ge})

(defn parse-formula
  "Parses the formula text `s` (without the leading `=`) and returns the
  syntax tree."
  [^String s]
  (let [toks (tokenize s)
        pos (volatile! 0)
        invalid? (volatile! false)
        peek-tok (fn [] (nth toks @pos nil))
        advance! (fn [] (let [t (nth toks @pos)] (vswap! pos inc) t))
        ref! (fn [text]
               (or (cell/parse-ref text)
                   (do (vreset! invalid? true) 0)))
        expr
        (fn expr []
          (letfn [(binary-level [sub ops build]
                    (fn []
                      (loop [l (sub)]
                        (let [t (peek-tok)]
                          (if (ops t)
                            (do (advance!) (recur (build t l (sub))))
                            l)))))
                  (primary []
                    (let [t (advance!)]
                      (cond
                        (= t :lparen) (let [e (expr)] (advance!) e)
                        (= (first t) :num) [:num (second t)]
                        (= (first t) :str) [:str (second t)]
                        (= (first t) :ref) [:ref (ref! (second t))]
                        :else (call (second t)))))
                  (unary []
                    (if (= :- (peek-tok))
                      (do (advance!) [:neg (unary)])
                      (primary)))
                  (call [name]
                    (advance!)                  ; (
                    (if (= name "IF")
                      (let [c (expr) _ (advance!) a (expr) _ (advance!) b (expr)]
                        (advance!)              ; )
                        [:if c a b])
                      (let [args (loop [args []]
                                   (let [a (arg)
                                         t (advance!)]
                                     (if (= t :comma) (recur (conj args a)) (conj args a))))]
                        [:agg (agg-fns name) args])))
                  (arg []
                    (let [t (peek-tok)]
                      (if (and (vector? t) (= (first t) :ref)
                               (= :colon (nth toks (inc @pos) nil)))
                        (do (advance!) (advance!)
                            (let [c2 (advance!)
                                  a (ref! (second t))
                                  b (ref! (second c2))]
                              [:range (min (cell/id->row a) (cell/id->row b))
                               (min (cell/id->col a) (cell/id->col b))
                               (max (cell/id->row a) (cell/id->row b))
                               (max (cell/id->col a) (cell/id->col b))]))
                        (expr))))
                  (mul [] ((binary-level unary #{:* :/} (fn [t l r] [:arith t l r]))))
                  (add [] ((binary-level mul #{:+ :-} (fn [t l r] [:arith t l r]))))
                  (cat [] ((binary-level add #{:cat} (fn [_ l r] [:cat l r]))))]
            ((binary-level cat cmp-ops (fn [t l r] [:cmp t l r])))))
        tree (expr)]
    (if @invalid? [:err :error/ref] tree)))

;;; Dependencies

(defn dependencies
  "Returns the set of cell ids that syntax tree `node` statically depends on:
  every referenced cell and every cell covered by a range."
  [node]
  (loop [stack [node] deps (transient #{})]
    (if (empty? stack)
      (persistent! deps)
      (let [n (peek stack)
            stack (pop stack)]
        (case (nth n 0)
          (:num :str :err) (recur stack deps)
          :ref (recur stack (conj! deps (nth n 1)))
          :neg (recur (conj stack (nth n 1)) deps)
          (:arith :cmp) (recur (conj stack (nth n 2) (nth n 3)) deps)
          :cat (recur (conj stack (nth n 1) (nth n 2)) deps)
          :if (recur (conj stack (nth n 1) (nth n 2) (nth n 3)) deps)
          :agg (recur (into stack (nth n 2)) deps)
          :range (let [[_ r1 c1 r2 c2] n]
                   (recur stack
                          (reduce conj! deps
                                  (for [r (range r1 (inc r2)) c (range c1 (inc c2))]
                                    (cell/->id c r))))))))))

;;; Cell content

(defn parse-content
  "Parses the content of a `set` command (a formula, string literal or number
  literal) and returns `{:ast tree :deps #{ids}}`."
  [^String content]
  (let [tree (cond
               (.startsWith content "=") (parse-formula (subs content 1))
               (.startsWith content "\"") [:str (subs content 1 (dec (.length content)))]
               :else [:num (let [d (Double/parseDouble content)] (if (zero? d) 0.0 d))])]
    {:ast tree :deps (dependencies tree)}))
