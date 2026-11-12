(ns cardgame.matchfile
  "Parser for match files (SPEC section 4): the setup block and the script
  lines.

  [[parse-setup]] and [[parse-line]] are pure.  Setup problems are reported
  by returning `{:error :bad-setup}`; malformed script lines by returning
  `{:bad-syntax true}`."
  (:require [clojure.string :as str]))

(def ^:private two-64 (.shiftLeft BigInteger/ONE 64))

(defn split-lines
  "Split `text` into lines on `\\n`, stripping one `\\r` before each; a final
  newline does not start a new line."
  [^String text]
  (let [parts (str/split text #"\n" -1)
        parts (if (and (seq parts) (= "" (peek parts))) (pop parts) parts)]
    (mapv (fn [^String l] (if (.endsWith l "\r") (subs l 0 (dec (count l))) l)) parts)))

(defn comment-line?
  "A comment or blank line: whitespace only, or first non-space is `#`."
  [^String line]
  (let [t (str/triml line)]
    (or (= "" t) (= \# (.charAt t 0)))))

(defn words
  "Split a line into words on runs of spaces and tabs."
  [^String line]
  (vec (remove str/blank? (str/split line #"[ \t]+"))))

(defn- digits? [^String s] (boolean (re-matches #"[0-9]+" s)))

(defn- num-in
  "Parse `s` as a decimal in [lo, hi], or nil."
  [s lo hi]
  (when (digits? s)
    (let [v (BigInteger. ^String s)]
      (when (and (>= (.compareTo v (biginteger lo)) 0) (<= (.compareTo v (biginteger hi)) 0))
        (long v)))))

(defn- parse-entries
  "Parse `<cardid>` / `<cardid>*<count>` words into `[cardid count]` pairs;
  nil if any word is malformed."
  [ws]
  (when (seq ws)
    (let [parsed (mapv (fn [^String w]
                         (let [i (.indexOf w "*")]
                           (cond
                             (neg? i) (when (seq w) [w 1])
                             (zero? i) nil
                             :else (when-let [n (num-in (subs w (inc i)) 1 1000)]
                                     [(subs w 0 i) n]))))
                       ws)]
      (when (every? some? parsed) parsed))))

(def ^:private zone-keys
  {"DECK" :deck "HAND" :hand "FIELD" :field "ASH" :ash "RIFT" :rift})

(def default-config
  {:spire 25 :opening 5 :maxcap 10 :handmax 7 :turnlimit 200 :first :A
   :shuffle true :trace :none :caps {} :zones {}})

(defn- setup-line
  "Apply one setup line (as `ws`) to `cfg`/`seen`.  Returns `[cfg seen]` or
  nil on error."
  [[cfg seen] ws]
  (let [cmd (first ws)
        n (count ws)
        once (fn [k] (when-not (contains? seen k) (conj seen k)))
        numeric (fn [key lo hi]
                  (when (= n 2)
                    (when-let [v (num-in (second ws) lo hi)]
                      (when-let [seen' (once cmd)]
                        [(assoc cfg key v) seen']))))]
    (case cmd
      "CARDS" (when (= n 2)
                (when-let [seen' (once cmd)] [(assoc cfg :cards (second ws)) seen']))
      "SEED" (when (= n 2)
               (when (digits? (second ws))
                 (let [v (BigInteger. ^String (second ws))]
                   (when (< (.compareTo v two-64) 0)
                     (when-let [seen' (once cmd)] [(assoc cfg :seed v) seen'])))))
      "SPIRE" (numeric :spire 1 1000000)
      "OPENING" (numeric :opening 0 20)
      "MAXCAP" (numeric :maxcap 1 100)
      "HANDMAX" (numeric :handmax 0 100)
      "TURNLIMIT" (numeric :turnlimit 1 100000)
      "FIRST" (when (and (= n 2) (#{"A" "B"} (second ws)))
                (when-let [seen' (once cmd)] [(assoc cfg :first (keyword (second ws))) seen']))
      "SHUFFLE" (when (and (= n 2) (#{"on" "off"} (second ws)))
                  (when-let [seen' (once cmd)] [(assoc cfg :shuffle (= "on" (second ws))) seen']))
      "TRACE" (when (and (= n 2) (#{"none" "legal" "state"} (second ws)))
                (when-let [seen' (once cmd)] [(assoc cfg :trace (keyword (second ws))) seen']))
      "CAP" (when (= n 3)
              (when (#{"A" "B"} (second ws))
                (when-let [v (num-in (nth ws 2) 0 100)]
                  (when-let [seen' (once (str cmd " " (second ws)))]
                    [(assoc-in cfg [:caps (keyword (second ws))] v) seen']))))
      ("DECK" "HAND" "FIELD" "ASH" "RIFT")
      (when (>= n 3)
        (when (#{"A" "B"} (second ws))
          (when-let [es (parse-entries (subvec ws 2))]
            [(update-in cfg [:zones (keyword (second ws)) (zone-keys cmd)] (fnil into []) es)
             seen])))
      nil)))

(defn parse-setup
  "Parse the setup block of the match file given as a vector of `lines`.
  Returns `{:cfg config :start index}` where `index` is the 0-based index of
  the first script line, or `{:error :bad-setup}`."
  [lines]
  (loop [i 0, st [default-config #{}]]
    (if (>= i (count lines))
      {:error :bad-setup}
      (let [line (nth lines i)]
        (if (comment-line? line)
          (recur (inc i) st)
          (let [ws (words line)]
            (if (= "START" (first ws))
              (let [[cfg _] st]
                (if (and (= 1 (count ws)) (:cards cfg) (:seed cfg))
                  {:cfg cfg :start (inc i)}
                  {:error :bad-setup}))
              (if-let [st' (setup-line st ws)]
                (recur (inc i) st')
                {:error :bad-setup}))))))))

;; ---------------------------------------------------------------------------
;; Script lines

(defn- parse-int
  "Decimal digits to a long (or bigint when it does not fit a long);
  nil when malformed or not below 2^64."
  [s]
  (when (digits? s)
    (let [v (BigInteger. ^String s)]
      (when (< (.compareTo v two-64) 0)
        (if (< (.bitLength v) 64) (.longValue v) (bigint v))))))

(defn- parse-objref [^String s]
  (when (and (> (count s) 1) (= \# (.charAt s 0)))
    (parse-int (subs s 1))))

(defn- parse-target [^String s]
  (cond
    (= s "A") :A
    (= s "B") :B
    (and (> (count s) 1) (= \# (.charAt s 0))) (parse-int (subs s 1))
    (and (> (count s) 1) (= \~ (.charAt s 0))) (when-let [n (parse-int (subs s 1))] [:c n])
    :else nil))

(defn- parse-pair [^String s]
  (let [i (.indexOf s ":")]
    (when (pos? i)
      (let [b (parse-objref (subs s 0 i))
            a (parse-objref (subs s (inc i)))]
        (when (and b a) [b a])))))

(defn- all-some [xs] (when (every? some? xs) (vec xs)))

(defn parse-action
  "Parse the words after the player word.  Returns an action map or nil."
  [ws]
  (let [n (count ws)]
    (case (first ws)
      "PASS" (when (= n 1) {:type :pass})
      "CONCEDE" (when (= n 1) {:type :concede})
      "PLAY" (when (>= n 2)
               (let [pos (parse-int (second ws))
                     ts (all-some (map parse-target (subvec ws 2)))]
                 (when (and pos ts) {:type :play :pos pos :targets ts})))
      "ACT" (when (>= n 3)
              (let [o (parse-objref (second ws))
                    idx (parse-int (nth ws 2))
                    ts (all-some (map parse-target (subvec ws 3)))]
                (when (and o idx ts) {:type :act :oid o :index idx :targets ts})))
      "ATTACK" (when-let [os (all-some (map parse-objref (rest ws)))]
                 {:type :attack :oids os})
      "BLOCK" (when-let [ps (all-some (map parse-pair (rest ws)))]
                {:type :block :pairs ps})
      nil)))

(defn parse-line
  "Parse one script line.  Returns nil for a comment line, otherwise a map:
  `{:action {...} :player P}`, `{:directive :dump|:legal|:vault}`,
  `{:directive :card :id id}`, or `{:bad-syntax true}`."
  [line]
  (if (comment-line? line)
    nil
    (let [ws (words line)
          w (first ws)]
      (case w
        ("A" "B") (if-let [a (parse-action (subvec ws 1))]
                    {:player (keyword w) :action a}
                    {:bad-syntax true})
        "DUMP" (if (= 1 (count ws)) {:directive :dump} {:bad-syntax true})
        "LEGAL" (if (= 1 (count ws)) {:directive :legal} {:bad-syntax true})
        "VAULT" (if (= 1 (count ws)) {:directive :vault} {:bad-syntax true})
        "CARD" (if (= 2 (count ws)) {:directive :card :id (second ws)} {:bad-syntax true})
        {:bad-syntax true}))))
