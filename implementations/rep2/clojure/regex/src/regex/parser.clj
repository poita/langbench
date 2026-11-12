(ns regex.parser
  "Recursive-descent parser: pattern string -> syntax tree.

  Syntax tree nodes are vectors whose first element is a keyword:

      [:char code]            literal character (integer code)
      [:any]                  `.`
      [:set table]            character class / class escape (see regex.charset)
      [:bol] [:eol]           `^` and `$`
      [:seq [node ...]]       concatenation (never has exactly one element)
      [:alt [node ...]]       alternation (always at least two branches)
      [:group n node]         capturing group number n (1-based)
      [:rep node min max]     quantifier; max is nil for unbounded

  Errors are reported with `ex-info` whose data has `:type ::syntax-error`,
  the `:pattern` and the `:index` of the offending character."
  (:require [regex.charset :as cs]))

(def max-count
  "Largest `n` / `m` accepted in a counted quantifier."
  100)

(defn- digit? [ch] (and ch (<= (int \0) (int ch) (int \9))))
(defn- alnum? [ch]
  (and ch (or (digit? ch) (<= (int \a) (int ch) (int \z)) (<= (int \A) (int ch) (int \Z)))))

(defn parse
  "Parses `pattern` and returns `{:ast node :groups n}` where n is the number of
  capturing groups.  Throws a `::syntax-error` ex-info on invalid input."
  [^String pattern]
  (let [n (.length pattern)
        pos (volatile! 0)
        ngroups (volatile! 0)
        fail (fn [msg]
               (throw (ex-info (str "Invalid pattern: " msg " at index " @pos
                                    " in " (pr-str pattern))
                               {:type ::syntax-error :pattern pattern :index @pos})))
        peek-ch (fn [] (when (< @pos n) (.charAt pattern (int @pos))))
        peek-at (fn [k] (when (< (+ @pos k) n) (.charAt pattern (int (+ @pos k)))))
        advance! (fn [] (vswap! pos inc))
        next-ch! (fn [] (let [c (peek-ch)] (when c (advance!)) c))
        ;; reads a decimal integer with no leading zeros
        read-int (fn []
                   (let [start @pos]
                     (while (digit? (peek-ch)) (advance!))
                     (when (= start @pos) (fail "expected a number"))
                     (when (and (> (- @pos start) 1) (= \0 (.charAt pattern (int start))))
                       (fail "leading zero in quantifier"))
                     (let [v (Long/parseLong (subs pattern start @pos))]
                       (when (> v max-count) (fail (str "count above " max-count)))
                       v)))
        ;; after a backslash: returns [:set table] or [:char code]
        read-escape (fn []
                      (advance!)
                      (let [c (next-ch!)]
                        (cond
                          (nil? c) (fail "dangling backslash")
                          (cs/escape-set c) [:set (cs/escape-set c)]
                          (alnum? c) (do (vswap! pos dec) (fail (str "unknown escape \\" c)))
                          :else [:char (int c)])))
        ;; one class item: [:set table] or [:char code]
        read-class-item (fn []
                          (let [c (peek-ch)]
                            (if (= c \\)
                              (read-escape)
                              (do (advance!) [:char (int c)]))))
        parse-class
        (fn []
          (advance!)                                       ; '['
          (let [negate? (when (= (peek-ch) \^) (advance!) true)
                tbl (cs/empty-set)]
            (loop [first? true]
              (let [c (peek-ch)]
                (cond
                  (nil? c) (fail "unterminated character class")
                  (= c \]) (if first?
                             (fail "empty character class")
                             (advance!))
                  :else
                  (let [[kind v] (read-class-item)]
                    (if (= kind :set)
                      (cs/union! tbl v)
                      (if (and (= (peek-ch) \-) (peek-at 1) (not= (peek-at 1) \]))
                        (do (advance!)
                            (let [[k2 hi] (read-class-item)]
                              (when (or (= k2 :set) (> v hi)) (fail "invalid range in character class"))
                              (cs/add-range! tbl v hi)))
                        (cs/add-char! tbl v)))
                    (recur false)))))
            [:set (if negate? (cs/negate tbl) tbl)]))]
    (letfn [(parse-alt []
              (loop [branches [(parse-seq)]]
                (if (= (peek-ch) \|)
                  (do (advance!) (recur (conj branches (parse-seq))))
                  (if (= 1 (count branches)) (first branches) [:alt branches]))))
            (parse-seq []
              (loop [items []]
                (let [c (peek-ch)]
                  (if (or (nil? c) (= c \|) (= c \)))
                    (case (count items)
                      0 [:seq []]
                      1 (first items)
                      [:seq items])
                    (recur (conj items (parse-piece)))))))
            (parse-piece []
              (let [atom (parse-atom)
                    q (peek-ch)
                    quant (case q
                            \* (do (advance!) [0 nil])
                            \+ (do (advance!) [1 nil])
                            \? (do (advance!) [0 1])
                            \{ (do (advance!)
                                   (let [lo (read-int)]
                                     (case (next-ch!)
                                       \} [lo lo]
                                       \, (if (= (peek-ch) \})
                                            (do (advance!) [lo nil])
                                            (let [hi (read-int)]
                                              (when-not (= (next-ch!) \}) (fail "expected }"))
                                              (when (< hi lo) (fail "quantifier range out of order"))
                                              [lo hi]))
                                       (fail "malformed quantifier"))))
                            nil)]
                (cond
                  (nil? quant) atom
                  (#{:bol :eol} (first atom)) (fail "quantifier after an anchor")
                  :else [:rep atom (quant 0) (quant 1)])))
            (parse-atom []
              (let [c (peek-ch)]
                (case c
                  \( (do (advance!)
                         (let [g (vswap! ngroups inc)
                               body (parse-alt)]
                           (when-not (= (peek-ch) \)) (fail "missing )"))
                           (advance!)
                           [:group g body]))
                  \[ (parse-class)
                  \. (do (advance!) [:any])
                  \^ (do (advance!) [:bol])
                  \$ (do (advance!) [:eol])
                  \\ (read-escape)
                  (\* \+ \? \{) (fail "nothing to repeat")
                  (\] \} \)) (fail (str "unexpected " c))
                  (do (advance!) [:char (int c)]))))]
      (let [ast (parse-alt)]
        (when (< @pos n) (fail "unmatched )"))
        {:ast ast :groups @ngroups}))))
