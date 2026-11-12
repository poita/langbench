(ns sqlitefile.query
  "Parser for the query language of SPEC Part 4. A line parses to a plain map:

      {:op :tables}
      {:op :schema :table \"t\"}
      {:op :count :table \"t\"}
      {:op :select :columns :all|[names] :table \"t\"
       :where [{:column \"c\" :op :=|:!=|:<|:<=|:>|:>=|:is|:is-not :literal v}]
       :order {:column \"c\" :desc? bool} :limit n}
      {:op :index :index \"i\" :literal v}

  Malformed input throws `ex-info` with `:type :sqlitefile/syntax`."
  (:require [clojure.string :as str]))

(set! *warn-on-reflection* true)

(defn- syntax-error [msg s i]
  (throw (ex-info msg {:type :sqlitefile/syntax :query s :at i})))

(defn- match
  "Match `re` anchored at index `i` of `s`; returns `[groups end]` or nil."
  [^java.util.regex.Pattern re ^String s ^long i]
  (let [m (.matcher re s)]
    (.region m (int i) (.length s))
    (when (.lookingAt m)
      [(let [g (.groupCount m)]
         (mapv #(.group m (int %)) (range (inc g))))
       (.end m)])))

(defn- skip-ws ^long [^String s ^long i]
  (loop [i i]
    (if (and (< i (.length s)) (#{\space \tab} (.charAt s i)))
      (recur (inc i))
      i)))

(defn- word
  "Read a maximal run of `[A-Za-z0-9_]` at `i`; returns `[text end]` or nil."
  [s i]
  (when-let [[[w] e] (match #"[A-Za-z0-9_]+" s i)] [w e]))

(defn- keyword-at
  "If the word at `i` is `kw` (case-insensitive) return the end index."
  [s i kw]
  (when-let [[w e] (word s i)]
    (when (.equalsIgnoreCase ^String w ^String kw) e)))

(defn- expect-keyword [s i kw]
  (or (keyword-at s i kw) (syntax-error (str "expected " kw) s i)))

(def ^:private identifier-re #"[A-Za-z_][A-Za-z0-9_]*")

(defn- identifier [s i]
  (if-let [[w e] (word s i)]
    (if (re-matches identifier-re w) [w e] (syntax-error "bad identifier" s i))
    (syntax-error "expected identifier" s i)))

(def ^:private numeral-re
  #"([+-]?[0-9]+(\.[0-9]*)?([eE][+-]?[0-9]+)?)(?![A-Za-z0-9_])")

(defn- literal
  "Parse a literal at `i`; returns `[value end]`."
  [^String s i]
  (let [c (when (< i (.length s)) (.charAt s i))]
    (cond
      (nil? c) (syntax-error "expected literal" s i)

      (= c \')
      (let [n (.length s) sb (StringBuilder.)]
        (loop [j (inc i)]
          (cond
            (>= j n) (syntax-error "unterminated string" s i)
            (= (.charAt s j) \') (if (and (< (inc j) n) (= (.charAt s (inc j)) \'))
                                   (do (.append sb \') (recur (+ j 2)))
                                   [(str sb) (inc j)])
            :else (do (.append sb (.charAt s j)) (recur (inc j))))))

      (and (#{\x \X} c) (< (inc i) (.length s)) (= (.charAt s (inc i)) \'))
      (let [close (.indexOf s "'" (int (+ i 2)))]
        (when (neg? close) (syntax-error "unterminated blob" s i))
        (let [hexs (subs s (+ i 2) close)]
          (when (or (odd? (count hexs)) (not (re-matches #"[0-9a-fA-F]*" hexs)))
            (syntax-error "malformed blob" s i))
          [(byte-array (map #(unchecked-byte (Integer/parseInt (subs hexs % (+ % 2)) 16))
                            (range 0 (count hexs) 2)))
           (inc close)]))

      (or (Character/isDigit (char c)) (#{\+ \-} c))
      (if-let [[[num _ frac exp] e] (match numeral-re s i)]
        [(if (or frac exp)
           (Double/parseDouble num)
           (Long/parseLong (if (str/starts-with? num "+") (subs num 1) num)))
         e]
        (syntax-error "malformed numeral" s i))

      :else
      (if-let [e (keyword-at s i "NULL")]
        [nil e]
        (syntax-error "expected literal" s i)))))

(defn- end-at [s i]
  (when-not (= (skip-ws s i) (.length ^String s))
    (syntax-error "trailing text" s i)))

(defn- parse-columns [s i]
  (if (and (< i (.length ^String s)) (= (.charAt ^String s i) \*))
    [:all (inc i)]
    (loop [i i cols []]
      (let [[name e] (identifier s i)
            cols (conj cols name)
            e (skip-ws s e)]
        (if (and (< e (.length ^String s)) (= (.charAt ^String s e) \,))
          (recur (skip-ws s (inc e)) cols)
          [cols e])))))

(def ^:private operators
  [["<=" :<=] [">=" :>=] ["!=" :!=] ["<" :<] [">" :>] ["=" :=]])

(defn- parse-operator [^String s i]
  (or (some (fn [[text op]] (when (.startsWith s ^String text (int i)) [op (+ i (count text))]))
            operators)
      (when-let [e (keyword-at s i "IS")]
        (let [e2 (skip-ws s e)]
          (if-let [e3 (keyword-at s e2 "NOT")]
            [:is-not e3]
            [:is e])))
      (syntax-error "unsupported operator" s i)))

(defn- parse-condition [s i]
  (let [[col e] (identifier s i)
        [op e] (parse-operator s (skip-ws s e))
        [lit e] (literal s (skip-ws s e))]
    [{:column col :op op :literal lit} e]))

(defn- parse-where [s i]
  (loop [i i conds []]
    (let [[c e] (parse-condition s (skip-ws s i))
          conds (conj conds c)
          e (skip-ws s e)]
      (if-let [e2 (keyword-at s e "AND")]
        (recur e2 conds)
        [conds e]))))

(defn- parse-select [s i]
  (let [[cols e] (parse-columns s (skip-ws s i))
        e (expect-keyword s (skip-ws s e) "FROM")
        [table e] (identifier s (skip-ws s e))
        e (skip-ws s e)
        [where e] (if-let [e2 (keyword-at s e "WHERE")] (parse-where s e2) [nil e])
        e (skip-ws s e)
        [order e] (if-let [e2 (keyword-at s e "ORDER")]
                    (let [e3 (expect-keyword s (skip-ws s e2) "BY")
                          [col e4] (identifier s (skip-ws s e3))
                          e5 (skip-ws s e4)]
                      (cond
                        (keyword-at s e5 "ASC") [{:column col :desc? false} (keyword-at s e5 "ASC")]
                        (keyword-at s e5 "DESC") [{:column col :desc? true} (keyword-at s e5 "DESC")]
                        :else [{:column col :desc? false} e4]))
                    [nil e])
        e (skip-ws s e)
        [limit e] (if-let [e2 (keyword-at s e "LIMIT")]
                    (let [[w e3] (or (word s (skip-ws s e2)) (syntax-error "expected limit" s e2))]
                      (when-not (re-matches #"[0-9]+" w) (syntax-error "bad limit" s e2))
                      [(Long/parseLong w) e3])
                    [nil e])]
    (end-at s e)
    (cond-> {:op :select :columns cols :table table}
      where (assoc :where where)
      order (assoc :order order)
      limit (assoc :limit limit))))

(defn- parse-dot [^String s]
  (cond
    (= s ".tables") {:op :tables}
    (str/starts-with? s ".schema ")
    (let [arg (subs s 8)]
      (if (re-matches identifier-re arg)
        {:op :schema :table arg}
        (syntax-error "bad .schema argument" s 8)))
    :else (syntax-error "unknown dot command" s 0)))

(defn parse
  "Parse one query line into a command map (see the namespace docstring)."
  [^String line]
  (if (str/starts-with? line ".")
    (parse-dot line)
    (let [i (skip-ws line 0)]
      (cond
        (keyword-at line i "SELECT") (parse-select line (keyword-at line i "SELECT"))
        (keyword-at line i "COUNT")
        (let [[table e] (identifier line (skip-ws line (keyword-at line i "COUNT")))]
          (end-at line e)
          {:op :count :table table})
        (keyword-at line i "INDEX")
        (let [[index e] (identifier line (skip-ws line (keyword-at line i "INDEX")))
              [lit e] (literal line (skip-ws line e))]
          (end-at line e)
          {:op :index :index index :literal lit})
        :else (syntax-error "unknown command" line i)))))
