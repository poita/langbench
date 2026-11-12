(ns minisql.parser
  "Recursive-descent parser: the tokens of one statement -> syntax tree.

  ## Expressions

  Expressions are vectors headed by a keyword:

      [:lit v]            literal (Long, String or nil)
      [:col qual name]    column reference; `qual` may be nil
      [:neg e]
      [:add a b] [:sub a b] [:mul a b] [:div a b] [:mod a b]
      [:lt a b] [:le a b] [:gt a b] [:ge a b] [:eq a b] [:ne a b]
      [:and a b] [:or a b] [:not e]
      [:is-null e] [:is-not-null e]
      [:like s pattern]
      [:agg f arg]        f in :count :sum :min :max :avg; arg is an
                          expression, or :star for COUNT(*)

  ## Statements

  Maps with a `:type` of `:create`, `:insert`, `:delete`, `:update` or
  `:select`; see the `parse-*` functions for their keys."
  (:require [minisql.error :as err]))

(def ^:private eof [:eof nil])

(defn- peek-tok
  ([p] (peek-tok p 0))
  ([p k] (nth (:toks p) (+ (long @(:pos p)) (long k)) eof)))

(defn- next! [p]
  (let [t (peek-tok p)]
    (vswap! (:pos p) inc)
    t))

(defn- kw-at? [tok k] (and (= :kw (nth tok 0)) (= k (nth tok 1))))
(defn- op-at? [tok s] (and (= :op (nth tok 0)) (= s (nth tok 1))))
(defn- id-at? [tok] (= :id (nth tok 0)))

(defn- accept-kw [p k] (when (kw-at? (peek-tok p) k) (next! p) true))
(defn- accept-op [p s] (when (op-at? (peek-tok p) s) (next! p) true))

(defn- expect-kw [p k]
  (or (accept-kw p k) (err/syntax! (str "expected " (name k)))))

(defn- expect-op [p s]
  (or (accept-op p s) (err/syntax! (str "expected " s))))

(defn- expect-id [p]
  (let [t (peek-tok p)]
    (if (id-at? t)
      (do (next! p) (nth t 1))
      (err/syntax! "expected an identifier"))))

(defn- int-literal [digits]
  (try (Long/parseLong digits)
       (catch NumberFormatException _ (err/syntax! "integer out of range"))))

(defn- parse-int [p]
  (let [t (peek-tok p)]
    (if (= :int (nth t 0))
      (do (next! p) (int-literal (nth t 1)))
      (err/syntax! "expected an integer"))))

;; ---------------------------------------------------------------- expressions

(declare parse-expr)

(def ^:private aggregate-fns
  {"count" :count "sum" :sum "min" :min "max" :max "avg" :avg})

(defn- parse-column-ref
  "`name` or `name . name` -> [:col qual name]."
  [p]
  (let [a (expect-id p)]
    (if (accept-op p ".")
      [:col a (expect-id p)]
      [:col nil a])))

(defn- parse-primary [p]
  (let [[ty v :as tok] (peek-tok p)]
    (case ty
      :int (do (next! p) [:lit (int-literal v)])
      :str (do (next! p) [:lit v])
      :kw (if (= v :null)
            (do (next! p) [:lit nil])
            (err/syntax! (str "unexpected keyword " (name v))))
      :op (if (= v "(")
            (do (next! p)
                (let [e (parse-expr p)]
                  (expect-op p ")")
                  e))
            (err/syntax! (str "unexpected " v)))
      :id (if (op-at? (peek-tok p 1) "(")
            (if-let [f (aggregate-fns v)]
              (do (next! p) (next! p)
                  (let [arg (if (and (= f :count) (accept-op p "*"))
                              :star
                              (parse-expr p))]
                    (expect-op p ")")
                    [:agg f arg]))
              (err/syntax! (str "unknown function " v)))
            (parse-column-ref p))
      (err/syntax! "unexpected token"))))

(defn- parse-unary [p]
  (if (accept-op p "-")
    [:neg (parse-unary p)]
    (parse-primary p)))

(defn- parse-left-assoc
  "Parse `sub { op sub }` where `ops` maps operator strings to node heads."
  [p sub ops]
  (loop [l (sub p)]
    (let [[ty v] (peek-tok p)]
      (if-let [head (and (= ty :op) (ops v))]
        (do (next! p) (recur [head l (sub p)]))
        l))))

(defn- parse-mul [p] (parse-left-assoc p parse-unary {"*" :mul "/" :div "%" :mod}))
(defn- parse-add [p] (parse-left-assoc p parse-mul {"+" :add "-" :sub}))
(defn- parse-rel [p] (parse-left-assoc p parse-add {"<" :lt "<=" :le ">" :gt ">=" :ge}))

(def ^:private eq-ops {"=" :eq "==" :eq "!=" :ne "<>" :ne})

(defn- parse-eq [p]
  (loop [l (parse-rel p)]
    (let [[ty v :as tok] (peek-tok p)]
      (cond
        (and (= ty :op) (eq-ops v))
        (do (next! p) (recur [(eq-ops v) l (parse-rel p)]))

        (kw-at? tok :is)
        (do (next! p)
            (let [negated (accept-kw p :not)]
              (expect-kw p :null)
              (recur [(if negated :is-not-null :is-null) l])))

        (kw-at? tok :like)
        (do (next! p) (recur [:like l (parse-rel p)]))

        (kw-at? tok :not)
        (do (next! p) (expect-kw p :like)
            (recur [:not [:like l (parse-rel p)]]))

        :else l))))

(defn- parse-not [p]
  (if (accept-kw p :not)
    [:not (parse-not p)]
    (parse-eq p)))

(defn- parse-and [p]
  (loop [l (parse-not p)]
    (if (accept-kw p :and) (recur [:and l (parse-not p)]) l)))

(defn- parse-expr [p]
  (loop [l (parse-and p)]
    (if (accept-kw p :or) (recur [:or l (parse-and p)]) l)))

;; ----------------------------------------------------------------- statements

(defn- comma-list
  "Parse `item {, item}` with `parse-item`."
  [p parse-item]
  (loop [acc [(parse-item p)]]
    (if (accept-op p ",")
      (recur (conj acc (parse-item p)))
      acc)))

(defn- parse-create [p]
  (expect-kw p :table)
  (let [name (expect-id p)]
    (expect-op p "(")
    (let [cols (comma-list p (fn [p]
                               (let [c (expect-id p)
                                     t (peek-tok p)]
                                 (if (or (kw-at? t :integer) (kw-at? t :text))
                                   (do (next! p) [c (nth t 1)])
                                   (err/syntax! "expected a column type")))))]
      (expect-op p ")")
      {:type :create :table name :columns cols})))

(defn- parse-insert [p]
  (expect-kw p :into)
  (let [name (expect-id p)]
    (expect-kw p :values)
    (let [rows (comma-list p (fn [p]
                               (expect-op p "(")
                               (let [r (comma-list p parse-expr)]
                                 (expect-op p ")")
                                 r)))]
      {:type :insert :table name :rows rows})))

(defn- parse-where [p]
  (when (accept-kw p :where) (parse-expr p)))

(defn- parse-delete [p]
  (expect-kw p :from)
  (let [name (expect-id p)]
    {:type :delete :table name :where (parse-where p)}))

(defn- parse-update [p]
  (let [name (expect-id p)]
    (expect-kw p :set)
    (let [sets (comma-list p (fn [p]
                               (let [c (expect-id p)]
                                 (expect-op p "=")
                                 [c (parse-expr p)])))]
      {:type :update :table name :set sets :where (parse-where p)})))

(defn- parse-optional-alias [p]
  (cond (accept-kw p :as) (expect-id p)
        (id-at? (peek-tok p)) (nth (next! p) 1)))

(defn- parse-table-ref [p]
  (let [name (expect-id p)]
    {:table name :alias (parse-optional-alias p)}))

(defn- parse-item [p]
  (if (accept-op p "*")
    {:star true}
    (let [e (parse-expr p)]
      {:expr e :alias (parse-optional-alias p)})))

(defn- parse-order-term [p]
  (let [start @(:pos p)
        e (parse-expr p)
        end @(:pos p)
        single (when (= 1 (- end start)) (nth (:toks p) start))
        desc (cond (accept-kw p :desc) true
                   (accept-kw p :asc) false
                   :else false)]
    {:expr e
     :name (when (and single (id-at? single)) (nth single 1))
     :ordinal (when (and single (= :int (nth single 0)))
                (try (Long/parseLong (nth single 1))
                     (catch NumberFormatException _ Long/MAX_VALUE)))
     :desc desc}))

(defn- and-all [a b]
  (cond (nil? a) b (nil? b) a :else [:and a b]))

(defn- parse-from
  "Returns `[tables on]`."
  [p]
  (let [t1 (parse-table-ref p)]
    (cond
      (accept-op p ",") [[t1 (parse-table-ref p)] nil]

      (or (kw-at? (peek-tok p) :join) (kw-at? (peek-tok p) :inner))
      (do (if (accept-kw p :inner) (expect-kw p :join) (next! p))
          (let [t2 (parse-table-ref p)]
            (expect-kw p :on)
            [[t1 t2] (parse-expr p)]))

      :else [[t1] nil])))

(defn- parse-select [p]
  (let [items (comma-list p parse-item)
        [tables on] (when (accept-kw p :from) (parse-from p))
        where (parse-where p)
        group-by (when (accept-kw p :group)
                   (expect-kw p :by)
                   (comma-list p parse-column-ref))
        having (when (accept-kw p :having)
                 (when-not group-by (err/syntax! "HAVING requires GROUP BY"))
                 (parse-expr p))
        order-by (when (accept-kw p :order)
                   (expect-kw p :by)
                   (comma-list p parse-order-term))
        limit (when (accept-kw p :limit) (parse-int p))
        offset (when (and limit (accept-kw p :offset)) (parse-int p))]
    {:type :select
     :items items
     :tables (or tables [])
     :where (and-all on where)
     :group-by (or group-by [])
     :having having
     :order-by (or order-by [])
     :limit limit
     :offset offset}))

(defn parse-statement
  "Parse the tokens of one statement (see `minisql.lexer/statements`) into a
  statement map.  Throws a syntax error (see `minisql.error`) on bad input.

  Statement shapes:

      {:type :create :table name :columns [[name :integer|:text] ...]}
      {:type :insert :table name :rows [[expr ...] ...]}
      {:type :delete :table name :where expr-or-nil}
      {:type :update :table name :set [[column expr] ...] :where expr-or-nil}
      {:type :select :items [{:star true} | {:expr e :alias a-or-nil} ...]
                     :tables [{:table name :alias a-or-nil} ...]  ; 0, 1 or 2
                     :where expr-or-nil                           ; ON merged in
                     :group-by [[:col qual name] ...]
                     :having expr-or-nil
                     :order-by [{:expr e :name n :ordinal k :desc bool} ...]
                     :limit n :offset n}"
  [tokens]
  (let [p {:toks tokens :pos (volatile! 0)}
        [ty v :as tok] (next! p)
        stmt (if (= ty :kw)
               (case v
                 :create (parse-create p)
                 :insert (parse-insert p)
                 :delete (parse-delete p)
                 :update (parse-update p)
                 :select (parse-select p)
                 (err/syntax! (str "unexpected keyword " (name v))))
               (err/syntax! "expected a statement"))]
    (when-not (= eof (peek-tok p))
      (err/syntax! "unexpected trailing input"))
    stmt))
