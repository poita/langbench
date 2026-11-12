(ns sqlitefile.ddl
  "A small parser for the `CREATE TABLE` and `CREATE INDEX` statements stored
  in `sqlite_schema` (SPEC Part 2). It extracts column names, declared types,
  the rowid alias and the columns of an index, and nothing else."
  (:require [clojure.string :as str]
            [sqlitefile.value :as value]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Tokenizer

(defn- word-char? [c]
  (let [c (int c)]
    (or (<= 97 c 122) (<= 65 c 90) (<= 48 c 57) (= c 95) (= c 36) (>= c 128))))

(defn- scan-quoted
  "Scan a quoted run starting at `i` (which holds the opening quote `q`) where
  a doubled `q` is a literal quote. Returns `[text next-index]`."
  [^String s ^long i q]
  (let [q (char q)
        n (.length s)
        sb (StringBuilder.)]
    (loop [j (inc i)]
      (cond
        (>= j n) [(str sb) n]
        (= (.charAt s j) q) (if (and (< (inc j) n) (= (.charAt s (inc j)) q))
                              (do (.append sb q) (recur (+ j 2)))
                              [(str sb) (inc j)])
        :else (do (.append sb (.charAt s j)) (recur (inc j)))))))

(defn tokenize
  "Split SQL text into tokens `{:type t :text s}` where `t` is one of
  `:word`, `:quoted`, `:string`, `:punct` or `:other`. Whitespace and
  comments are dropped."
  [^String s]
  (let [n (.length s)]
    (loop [i 0 out (transient [])]
      (if (>= i n)
        (persistent! out)
        (let [c (.charAt s i)]
          (cond
            (Character/isWhitespace c) (recur (inc i) out)
            (and (= c \-) (< (inc i) n) (= (.charAt s (inc i)) \-))
            (let [e (.indexOf s "\n" (int i))] (recur (long (if (neg? e) n e)) out))
            (and (= c \/) (< (inc i) n) (= (.charAt s (inc i)) \*))
            (let [e (.indexOf s "*/" (int (+ i 2)))] (recur (long (if (neg? e) n (+ e 2))) out))
            (word-char? c)
            (let [e (long (loop [j i] (if (and (< j n) (word-char? (.charAt s j))) (recur (inc j)) j)))]
              (recur e (conj! out {:type :word :text (subs s i e)})))
            (or (= c \") (= c \`))
            (let [[t e] (scan-quoted s i c)] (recur (long e) (conj! out {:type :quoted :text t})))
            (= c \')
            (let [[t e] (scan-quoted s i c)] (recur (long e) (conj! out {:type :string :text t})))
            (= c \[)
            (let [e (.indexOf s "]" (int i))
                  e (long (if (neg? e) n e))]
              (recur (min n (inc e)) (conj! out {:type :quoted :text (subs s (inc i) e)})))
            (#{\( \) \, \. \;} c) (recur (inc i) (conj! out {:type :punct :text (str c)}))
            :else (recur (inc i) (conj! out {:type :other :text (str c)}))))))))

(defn- kw?
  "Is token `t` the unquoted keyword `k`?"
  [t k]
  (and (= :word (:type t)) (.equalsIgnoreCase ^String (:text t) ^String k)))

(defn- punct? [t p] (and (= :punct (:type t)) (= p (:text t))))

(defn- name-token? [t] (#{:word :quoted} (:type t)))

(defn- split-top-level
  "Split `tokens` at commas at paren depth 0."
  [tokens]
  (loop [ts (seq tokens) depth 0 cur [] out []]
    (if-let [[t & more] ts]
      (cond
        (punct? t "(") (recur more (inc depth) (conj cur t) out)
        (punct? t ")") (recur more (dec depth) (conj cur t) out)
        (and (zero? depth) (punct? t ",")) (recur more depth [] (conj out cur))
        :else (recur more depth (conj cur t) out))
      (if (seq cur) (conj out cur) out))))

(defn- body-tokens
  "Tokens between the first `(` at or after index `from` and its matching `)`.
  Returns nil when there is no parenthesised body."
  [tokens from]
  (let [tv (vec tokens)
        open (first (keep-indexed (fn [i t] (when (and (>= i from) (punct? t "(")) i)) tv))]
    (when open
      (loop [i (inc open) depth 1 out []]
        (cond
          (>= i (count tv)) out
          (punct? (tv i) "(") (recur (inc i) (inc depth) (conj out (tv i)))
          (punct? (tv i) ")") (if (= depth 1) out (recur (inc i) (dec depth) (conj out (tv i))))
          :else (recur (inc i) depth (conj out (tv i))))))))

;; ---------------------------------------------------------------------------
;; CREATE TABLE

(def ^:private type-stop-words
  #{"CONSTRAINT" "PRIMARY" "NOT" "NULL" "UNIQUE" "CHECK" "DEFAULT" "COLLATE"
    "REFERENCES" "GENERATED" "AS" "AUTOINCREMENT"})

(def ^:private table-constraint-words #{"CONSTRAINT" "PRIMARY" "UNIQUE" "CHECK" "FOREIGN"})

(defn- stop-word? [t]
  (and (= :word (:type t)) (contains? type-stop-words (str/upper-case (:text t)))))

(defn- depth0-tokens
  "The tokens of `ts` that sit at paren depth 0 (parens themselves excluded)."
  [ts]
  (loop [ts (seq ts) depth 0 out []]
    (if-let [[t & more] ts]
      (cond
        (punct? t "(") (recur more (inc depth) out)
        (punct? t ")") (recur more (dec depth) out)
        (zero? depth) (recur more depth (conj out t))
        :else (recur more depth out))
      out)))

(defn- parse-column [item]
  (let [[name-tok & more] item
        [type-toks rest-toks] (loop [ts (seq more) depth 0 acc []]
                                (if-let [[t & r] ts]
                                  (cond
                                    (punct? t "(") (recur r (inc depth) (conj acc t))
                                    (punct? t ")") (recur r (dec depth) (conj acc t))
                                    (and (zero? depth) (stop-word? t)) [acc ts]
                                    :else (recur r depth (conj acc t)))
                                  [acc nil]))
        type-text (str/join " " (map :text type-toks))
        flat (depth0-tokens rest-toks)
        pk-at (first (keep-indexed (fn [i t]
                                     (when (and (kw? t "PRIMARY") (kw? (nth flat (inc i) nil) "KEY")) i))
                                   flat))]
    {:name (:text name-tok)
     :type type-text
     :affinity (value/affinity type-text)
     :integer? (and (= 1 (count type-toks)) (kw? (first type-toks) "INTEGER"))
     :primary-key? (some? pk-at)
     :pk-desc? (boolean (and pk-at (kw? (nth flat (+ pk-at 2) nil) "DESC")))}))

(defn- table-pk-column
  "For a table constraint item, the name of the single column in a
  `PRIMARY KEY (...)` constraint, or nil."
  [item]
  (let [item (if (kw? (first item) "CONSTRAINT") (drop 2 item) item)]
    (when (and (kw? (first item) "PRIMARY") (kw? (second item) "KEY"))
      (let [cols (split-top-level (body-tokens item 0))]
        (when (and (= 1 (count cols)) (name-token? (ffirst cols)))
          (:text (ffirst cols)))))))

(defn- ci= [a b] (.equalsIgnoreCase ^String a ^String b))

(defn parse-create-table
  "Parse a `CREATE TABLE` statement into
  `{:columns [{:name :type :affinity} ...] :rowid-alias index-or-nil}`.
  Throws `ex-info` when the statement does not have the expected shape."
  [sql]
  (let [tokens (tokenize sql)
        body (body-tokens tokens 0)]
    (when-not (and (kw? (first tokens) "CREATE") body)
      (throw (ex-info "not a CREATE TABLE statement" {:sql sql})))
    (let [items (split-top-level body)
          constraint? (fn [item] (and (= :word (:type (first item)))
                                      (contains? table-constraint-words
                                                 (str/upper-case (:text (first item))))))
          cols (mapv parse-column (remove constraint? items))
          table-pk (some table-pk-column (filter constraint? items))
          alias-idx (or (first (keep-indexed
                                (fn [i c] (when (and (:primary-key? c) (not (:pk-desc? c)) (:integer? c)) i))
                                cols))
                        (when table-pk
                          (first (keep-indexed
                                  (fn [i c] (when (and (ci= (:name c) table-pk) (:integer? c)) i))
                                  cols))))]
      {:columns (mapv #(select-keys % [:name :type :affinity]) cols)
       :rowid-alias alias-idx})))

;; ---------------------------------------------------------------------------
;; CREATE INDEX

(defn parse-create-index
  "Parse a `CREATE INDEX` statement into `{:table name :columns [name ...]}`."
  [sql]
  (let [tokens (vec (tokenize sql))
        on (first (keep-indexed (fn [i t] (when (kw? t "ON") i)) tokens))]
    (when-not (and (kw? (first tokens) "CREATE") on)
      (throw (ex-info "not a CREATE INDEX statement" {:sql sql})))
    (let [table-tok (nth tokens (inc on))
          table-tok (if (punct? (nth tokens (+ on 2) nil) ".") (nth tokens (+ on 3)) table-tok)
          body (body-tokens tokens (inc on))]
      (when-not (and body (name-token? table-tok))
        (throw (ex-info "malformed CREATE INDEX" {:sql sql})))
      {:table (:text table-tok)
       :columns (mapv (comp :text first) (split-top-level body))})))
