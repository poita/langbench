(ns kvstore.parser
  "Recursive-descent parser for the command language (spec sections 6 and 17).

  `parse-line` turns a line of text into a command map.  Tokens are resolved
  as the parser consumes them, so the first problem in source order is the
  one reported (spec 18.2).  Problems are `ex-info` exceptions whose
  `:kind` is one of `:syntax :unknown-command :bad-utf8 :int-range
  :dup-field :depth :bad-key :bad-path`.

  Command maps:

      {:cmd :put    :key bytes :doc value}
      {:cmd :get    :key bytes}      {:cmd :delete :key bytes}
      {:cmd :update :key bytes :path [seg ...] :value value}
      {:cmd :unset  :key bytes :path [seg ...]}
      {:cmd :scan   :from bytes? :to bytes? :limit n? :reverse bool :keys bool}
      {:cmd :find   :pred pred :limit n?}
      {:cmd :create-index :path [seg ...]}  {:cmd :drop-index :path [seg ...]}
      {:cmd :begin} {:cmd :commit} {:cmd :rollback} {:cmd :checkpoint}
      {:cmd :stat} {:cmd :indexes}

  Predicates:

      [:and p q] [:or p q] [:not p] [:exists path] [:missing path]
      [:cmp op path value]   ; op is \"==\" \"!=\" \"<\" \"<=\" \">\" \">=\""
  (:require [clojure.string :as str]
            [kvstore.bytes :as b]
            [kvstore.lexer :as lexer]
            [kvstore.limits :as lim]))

(set! *warn-on-reflection* true)

(defn- fail [kind]
  (throw (ex-info (name kind) {:kind kind})))

;; ---------------------------------------------------------------------------
;; Token cursor

(defn- cursor [tokens] (volatile! {:toks tokens :i 0}))

(defn- peek-tok
  ([c] (peek-tok c 0))
  ([c k] (let [{:keys [toks i]} @c] (get toks (+ i k)))))

(defn- advance! [c]
  (vswap! c update :i inc)
  nil)

(defn- next-tok! [c]
  (let [t (peek-tok c)]
    (when-not t (fail :syntax))
    (advance! c)
    t))

(defn- punct? [tok s] (and tok (= :punct (tok 0)) (= s (tok 1))))
(defn- word? ([tok] (and tok (= :word (tok 0)))) ([tok s] (and tok (= :word (tok 0)) (= s (tok 1)))))

(defn- expect-punct! [c s]
  (if (punct? (peek-tok c) s) (advance! c) (fail :syntax)))

(defn- expect-end! [c]
  (when (peek-tok c) (fail :syntax)))

;; ---------------------------------------------------------------------------
;; Token resolution

(defn- resolve-string
  "Text of a string token; `:bad-utf8` for an unpaired surrogate."
  ^String [tok]
  (when-not (and tok (= :string (tok 0))) (fail :syntax))
  (let [^String s (tok 1)
        n (.length s)]
    (loop [i 0]
      (when (< i n)
        (let [ch (.charAt s i)]
          (cond
            (Character/isHighSurrogate ch)
            (if (and (< (inc i) n) (Character/isLowSurrogate (.charAt s (inc i))))
              (recur (+ i 2))
              (fail :bad-utf8))
            (Character/isLowSurrogate ch) (fail :bad-utf8)
            :else (recur (inc i))))))
    s))

(defn- resolve-int
  "Value of an int token; `:int-range` outside signed 64 bits."
  ^long [tok]
  (when-not (and tok (= :int (tok 0))) (fail :syntax))
  (try (Long/parseLong ^String (tok 1))
       (catch NumberFormatException _ (fail :int-range))))

(defn- key-arg!
  "Consume a key argument: a string token of 1..128 UTF-8 bytes."
  [c]
  (let [^String s (resolve-string (next-tok! c))
        bs (b/utf8 s)]
    (when (or (zero? (alength bs)) (> (alength bs) lim/max-key)) (fail :bad-key))
    bs))

(defn- limit-arg! [c]
  (let [n (resolve-int (next-tok! c))]
    (when (or (neg? n) (> n lim/max-limit)) (fail :syntax))
    n))

;; ---------------------------------------------------------------------------
;; Values

(declare parse-value! parse-pred!)

(defn- parse-list! [c level]
  (if (punct? (peek-tok c) "]")
    (do (advance! c) [])
    (loop [acc [(parse-value! c (inc level))]]
      (let [t (next-tok! c)]
        (cond
          (punct? t "]") acc
          (punct? t ",") (recur (conj acc (parse-value! c (inc level))))
          :else (fail :syntax))))))

(defn- parse-name! [c]
  (let [t (next-tok! c)]
    (case (t 0)
      :word (t 1)
      :string (resolve-string t)
      (fail :syntax))))

(defn- parse-object! [c level]
  (if (punct? (peek-tok c) "}")
    (do (advance! c) {})
    (loop [acc {}]
      (let [name (parse-name! c)
            _ (when (contains? acc name) (fail :dup-field))
            _ (expect-punct! c ":")
            x (parse-value! c (inc level))
            acc (assoc acc name x)
            t (next-tok! c)]
        (cond
          (punct? t "}") acc
          (punct? t ",") (recur acc)
          :else (fail :syntax))))))

(defn- parse-value!
  "Parse a value literal at nesting `level` (the outermost value is level 1)."
  [c ^long level]
  (when (> level lim/max-depth) (fail :depth))
  (let [t (next-tok! c)]
    (case (t 0)
      :word (case (t 1)
              "null" nil
              "true" true
              "false" false
              (fail :syntax))
      :int (resolve-int t)
      :string (resolve-string t)
      :punct (case (t 1)
               "[" (parse-list! c level)
               "{" (parse-object! c level)
               (fail :syntax))
      (fail :syntax))))

;; ---------------------------------------------------------------------------
;; Paths

(defn- parse-path!
  "Parse `WORD { . WORD }`, checking the segment-count and byte limits as each
  segment is consumed.  Returns a vector of segments."
  [c]
  (loop [segs [] len 0]
    (let [t (next-tok! c)]
      (when-not (word? t) (fail :syntax))
      (let [segs (conj segs (t 1))
            len (+ len (count (t 1)) (if (> (count segs) 1) 1 0))]
        (when (or (> (count segs) lim/max-path-segments) (> len lim/max-path))
          (fail :bad-path))
        (if (punct? (peek-tok c) ".")
          (do (advance! c) (recur segs len))
          segs)))))

;; ---------------------------------------------------------------------------
;; Predicates

(defn- parse-term! [c]
  (let [t (peek-tok c)
        t1 (peek-tok c 1)]
    (cond
      (punct? t "(") (do (advance! c)
                         (let [p (parse-pred! c)]
                           (expect-punct! c ")")
                           p))
      (and (word? t "not") (punct? t1 "("))
      (do (advance! c) (advance! c)
          (let [p (parse-pred! c)]
            (expect-punct! c ")")
            [:not p]))
      (and (word? t "exists") (word? t1)) (do (advance! c) [:exists (parse-path! c)])
      (and (word? t "missing") (word? t1)) (do (advance! c) [:missing (parse-path! c)])
      (word? t) (let [path (parse-path! c)
                      op (next-tok! c)]
                  (when-not (= :op (op 0)) (fail :syntax))
                  [:cmp (op 1) path (parse-value! c 1)])
      :else (fail :syntax))))

(defn- parse-conj! [c]
  (loop [left (parse-term! c)]
    (if (word? (peek-tok c) "and")
      (do (advance! c) (recur [:and left (parse-term! c)]))
      left)))

(defn- parse-pred! [c]
  (loop [left (parse-conj! c)]
    (if (word? (peek-tok c) "or")
      (do (advance! c) (recur [:or left (parse-conj! c)]))
      left)))

;; ---------------------------------------------------------------------------
;; Commands

(defn- parse-scan! [c]
  (loop [opts {:reverse false :keys false}]
    (let [t (peek-tok c)]
      (if-not t
        opts
        (let [w (when (word? t) (t 1))]
          (when (or (nil? w) (not (#{"from" "to" "limit" "reverse" "keys"} w))) (fail :syntax))
          (let [k (keyword w)]
            (when (get opts k)
              (fail :syntax))
            (advance! c)
            (recur
             (case w
               "reverse" (assoc opts :reverse true)
               "keys" (assoc opts :keys true)
               "limit" (assoc opts :limit (limit-arg! c))
               ("from" "to") (assoc opts k (b/utf8 (resolve-string (next-tok! c))))))))))))

(defn- parse-find! [c]
  (let [pred (parse-pred! c)
        limit (when (word? (peek-tok c) "limit")
                (advance! c)
                (limit-arg! c))]
    (cond-> {:cmd :find :pred pred} limit (assoc :limit limit))))

(defn- parse-index-cmd! [c cmd]
  (when-not (word? (next-tok! c) "index") (fail :syntax))
  {:cmd cmd :path (parse-path! c)})

(def ^:private simple-commands
  {"begin" :begin "commit" :commit "rollback" :rollback "checkpoint" :checkpoint
   "stat" :stat "indexes" :indexes})

(def ^:private command-words
  #{"begin" "commit" "rollback" "checkpoint" "stat" "indexes" "put" "get" "delete"
    "update" "unset" "scan" "find" "create" "drop"})

(defn parse-tokens
  "Parse a token vector into a command map."
  [tokens]
  (let [c (cursor tokens)
        t (peek-tok c)]
    (when-not (word? t) (fail :syntax))
    (let [w (t 1)]
      (when-not (command-words w) (fail :unknown-command))
      (advance! c)
      (let [cmd
            (if-let [k (simple-commands w)]
              {:cmd k}
              (case w
                "put" (let [k (key-arg! c)] {:cmd :put :key k :doc (parse-value! c 1)})
                "get" {:cmd :get :key (key-arg! c)}
                "delete" {:cmd :delete :key (key-arg! c)}
                "update" (let [k (key-arg! c) p (parse-path! c)]
                           {:cmd :update :key k :path p :value (parse-value! c 1)})
                "unset" (let [k (key-arg! c)] {:cmd :unset :key k :path (parse-path! c)})
                "scan" (assoc (parse-scan! c) :cmd :scan)
                "find" (parse-find! c)
                "create" (parse-index-cmd! c :create-index)
                "drop" (parse-index-cmd! c :drop-index)))]
        (expect-end! c)
        cmd))))

(defn parse-line
  "Lex and parse one command line."
  [^String line]
  (parse-tokens (lexer/tokenize line)))

(defn parse-predicate
  "Parse the text of a predicate (as used after `find`), e.g.
  `age > 30 and name == \"ada\"`.  Trailing tokens are a syntax error."
  [^String text]
  (let [c (cursor (lexer/tokenize text))
        p (parse-pred! c)]
    (expect-end! c)
    p))
