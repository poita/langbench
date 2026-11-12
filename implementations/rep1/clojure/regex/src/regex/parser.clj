(ns regex.parser
  "Recursive-descent parser turning a pattern string into a syntax tree.

  Tree nodes are vectors tagged with a keyword:

      [:char c]          literal character
      [:any]             `.`
      [:set bools]       character class or class escape (see regex.charset)
      [:bol] / [:eol]    `^` / `$`
      [:seq [node ...]]  concatenation (possibly empty)
      [:alt [node ...]]  alternation, in priority order
      [:group n node]    capturing group number n (1-based)
      [:rep node min max]  greedy repetition; `max` is nil when unbounded"
  (:require [regex.charset :as cs]))

(defn- fail [^String src pos msg]
  (throw (ex-info (str "Invalid pattern: " msg " at offset " pos " in " (pr-str src))
                  {:pattern src :offset pos})))

;; Parser state: the source, a mutable cursor and the running group count.
(defn- new-parser [^String src]
  {:src src :pos (volatile! 0) :groups (volatile! 0)})

(defn- peek-char [{:keys [^String src pos]}]
  (let [p (long @pos)]
    (when (< p (.length src)) (.charAt src p))))

(defn- advance! [{:keys [pos]}] (vswap! pos inc))

(defn- next-char! [p]
  (let [c (peek-char p)]
    (when (nil? c) (fail (:src p) @(:pos p) "unexpected end of pattern"))
    (advance! p)
    c))

(defn- expect! [p ch]
  (when-not (= ch (peek-char p))
    (fail (:src p) @(:pos p) (str "expected " ch)))
  (advance! p))

(defn- alnum? [c]
  (or (Character/isLetterOrDigit (char c))))

(defn- parse-escaped-char!
  "After a backslash: a non-alphanumeric character stands for itself."
  [p]
  (let [c (next-char! p)]
    (when (alnum? c) (fail (:src p) (dec @(:pos p)) (str "unsupported escape \\" c)))
    c))

(defn- parse-class-single!
  "A single class member character (plain, or escaped punctuation)."
  [p]
  (let [c (next-char! p)]
    (if (= c \\) (parse-escaped-char! p) c)))

(defn- parse-class! [p]
  ;; the opening `[` has been consumed
  (let [negated? (when (= \^ (peek-char p)) (advance! p) true)
        set (cs/empty-set)]
    (loop []
      (let [c (peek-char p)]
        (cond
          (nil? c) (fail (:src p) @(:pos p) "unterminated class")
          (= c \]) (advance! p)
          :else
          (do
            (if (and (= c \\) (contains? cs/escape-sets
                                         (let [src ^String (:src p), q (inc (long @(:pos p)))]
                                           (when (< q (.length src)) (.charAt src q)))))
              (do (advance! p)
                  (cs/union! set (cs/escape-sets (next-char! p))))
              (let [lo (parse-class-single! p)]
                (if (and (= \- (peek-char p))
                         (let [src ^String (:src p), q (inc (long @(:pos p)))]
                           (and (< q (.length src)) (not= \] (.charAt src q)))))
                  (do (advance! p)
                      (let [hi (parse-class-single! p)]
                        (when (pos? (compare lo hi))
                          (fail (:src p) @(:pos p) "reversed range in class"))
                        (cs/add-range! set lo hi)))
                  (cs/add-range! set lo lo))))
            (recur)))))
    [:set (if negated? (cs/negate set) set)]))

(defn- parse-int! [p]
  (let [start @(:pos p)]
    (loop [n 0 any? false]
      (let [c (peek-char p)]
        (if (and c (<= (int \0) (int c) (int \9)))
          (do (advance! p) (recur (+ (* n 10) (- (int c) (int \0))) true))
          (if any? n (fail (:src p) start "expected a number")))))))

(declare parse-alt!)

(defn- parse-atom! [p]
  (let [c (next-char! p)]
    (case c
      \. [:any]
      \^ [:bol]
      \$ [:eol]
      \[ (parse-class! p)
      \( (let [n (vswap! (:groups p) inc)
               inner (parse-alt! p)]
           (expect! p \))
           [:group n inner])
      \\ (let [e (next-char! p)]
           (if-let [set (cs/escape-sets e)]
             [:set set]
             (do (when (alnum? e)
                   (fail (:src p) (dec @(:pos p)) (str "unsupported escape \\" e)))
                 [:char e])))
      [:char c])))

(defn- parse-quantifier!
  "Returns [min max] (max nil when unbounded) or nil when there is none."
  [p]
  (case (peek-char p)
    \* (do (advance! p) [0 nil])
    \+ (do (advance! p) [1 nil])
    \? (do (advance! p) [0 1])
    \{ (do (advance! p)
           (let [lo (parse-int! p)]
             (case (next-char! p)
               \} [lo lo]
               \, (if (= \} (peek-char p))
                    (do (advance! p) [lo nil])
                    (let [hi (parse-int! p)]
                      (expect! p \})
                      (when (< hi lo) (fail (:src p) @(:pos p) "bad repetition bounds"))
                      [lo hi]))
               (fail (:src p) @(:pos p) "malformed quantifier"))))
    nil))

(defn- parse-piece! [p]
  (let [atom (parse-atom! p)]
    (if-let [[lo hi] (parse-quantifier! p)]
      [:rep atom lo hi]
      atom)))

(defn- parse-branch! [p]
  (loop [items []]
    (let [c (peek-char p)]
      (if (or (nil? c) (= c \|) (= c \)))
        (if (== 1 (count items)) (first items) [:seq items])
        (recur (conj items (parse-piece! p)))))))

(defn- parse-alt! [p]
  (loop [branches [(parse-branch! p)]]
    (if (= \| (peek-char p))
      (do (advance! p) (recur (conj branches (parse-branch! p))))
      (if (== 1 (count branches)) (first branches) [:alt branches]))))

(defn parse
  "Parse `pattern` into `{:ast node, :groups n}` where n is the number of
  capturing groups. Throws `ex-info` (with `:pattern` and `:offset`) when the
  pattern is not valid."
  [^String pattern]
  (let [p (new-parser pattern)
        ast (parse-alt! p)]
    (when (peek-char p)
      (fail pattern @(:pos p) "unbalanced )"))
    {:ast ast :groups @(:groups p)}))
