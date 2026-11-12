(ns jsonschema.regex
  "A small ECMA-262-flavoured regular-expression engine for JSON Schema
  `pattern` / `patternProperties`.

  Only *membership* is answered: [[search?]] reports whether a pattern matches
  anywhere in a string. Matching is over Unicode code points, there are no
  flags, `^` / `$` anchor only at the very start / end of the subject, and
  `\\b` is a boundary over `[A-Za-z0-9_]`.

  Supported syntax: alternation, grouping `(...)` / `(?:...)`, the quantifiers
  `* + ? {n} {n,} {n,m}` (each optionally lazy), `.`, `^`, `$`, `\\b`, `\\B`,
  character classes with ranges and class escapes, and the character escapes
  `\\n \\r \\t \\f \\v \\0 \\xHH \\uHHHH \\cX` plus escaped punctuation.

  Implementation: the pattern is parsed to a syntax tree ([[parse]]), counted
  repetition is expanded while compiling to a Thompson-style NFA program
  ([[compile-pattern]]), and the program is simulated over all start positions
  at once, so a test costs O(P*L) for a pattern of size P and a subject of
  length L, with no exponential backtracking."
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Code-point range sets: sorted, non-overlapping vectors of [lo hi] (inclusive)

(def ^:private max-cp 0x10FFFF)

(defn- normalize-ranges [ranges]
  (let [sorted (sort-by first ranges)]
    (loop [[[lo hi :as r] & more] sorted, out []]
      (if-not r
        out
        (let [[plo phi] (peek out)]
          (if (and (seq out) (<= lo (inc phi)))
            (recur more (conj (pop out) [plo (max phi hi)]))
            (recur more (conj out [lo hi]))))))))

(defn- complement-ranges [ranges]
  (let [ranges (normalize-ranges ranges)]
    (loop [[[lo hi] & more :as rs] (seq ranges), start 0, out []]
      (if-not rs
        (if (<= start max-cp) (conj out [start max-cp]) out)
        (recur more (long (inc hi)) (if (< start lo) (conj out [start (dec lo)]) out))))))

(def ^:private digit-ranges [[48 57]])
(def ^:private word-ranges [[48 57] [65 90] [95 95] [97 122]])
(def ^:private space-ranges
  [[9 13] [32 32] [0xA0 0xA0] [0x1680 0x1680] [0x2000 0x200A] [0x2028 0x2029]
   [0x202F 0x202F] [0x205F 0x205F] [0x3000 0x3000] [0xFEFF 0xFEFF]])
(def ^:private line-terminators [[10 10] [13 13] [0x2028 0x2029]])

(defn- ranges->array ^longs [ranges]
  (let [r (normalize-ranges ranges)
        a (long-array (* 2 (count r)))]
    (dotimes [i (count r)]
      (aset a (* 2 i) (long (first (nth r i))))
      (aset a (inc (* 2 i)) (long (second (nth r i)))))
    a))

(defn- in-ranges?
  "Binary search of code point `cp` in the flattened range array."
  [^longs a ^long cp]
  (loop [lo 0 hi (dec (quot (alength a) 2))]
    (if (> lo hi)
      false
      (let [mid (quot (+ lo hi) 2)
            rlo (aget a (* 2 mid))
            rhi (aget a (inc (* 2 mid)))]
        (cond (< cp rlo) (recur lo (dec mid))
              (> cp rhi) (recur (inc mid) hi)
              :else true)))))


;; ---------------------------------------------------------------------------
;; Parser: pattern string -> syntax tree
;;
;; Nodes: [:empty] [:char cp] [:any] [:class ranges] [:seq nodes] [:alt nodes]
;;        [:rep node min max greedy?] (max nil = unbounded)
;;        [:bol] [:eol] [:wordb] [:nwordb]

(defn- syntax-error [msg pattern]
  (throw (ex-info (str "Invalid regular expression: " msg) {:type ::syntax-error :pattern pattern})))

(defn- hex-digit ^long [^long c] (Character/digit (int c) 16))

(defn- atom-ranges [[kind v]]
  (if (= kind :cp) [[v v]] v))

(defn parse
  "Parses `pattern` (a string) into a syntax tree. Throws `ex-info` with
  `:type ::syntax-error` on invalid or unsupported syntax."
  [^String pattern]
  (let [^ints cps (.toArray (.codePoints pattern))
        n (alength cps)
        pos (volatile! 0)
        cur (fn ^long [] (if (< @pos n) (aget cps @pos) -1))
        at (fn ^long [^long k] (if (< (+ @pos k) n) (aget cps (+ @pos k)) -1))
        adv! (fn [] (vswap! pos inc))
        err (fn [msg] (syntax-error msg pattern))
        hex-at (fn [start len]
                 ;; value of `len` hex digits starting at `start`, or nil
                 (when (<= (+ start len) n)
                   (loop [i 0, v 0]
                     (if (== i len)
                       v
                       (let [d (hex-digit (aget cps (+ start i)))]
                         (when-not (neg? d) (recur (inc i) (+ (* v 16) d))))))))
        ;; pos is just after the backslash. Returns [:cp n], [:ranges r],
        ;; or (outside classes) [:wordb] / [:nwordb].
        parse-escape
        (fn [in-class?]
          (let [c (cur)]
            (when (neg? c) (err "trailing backslash"))
            (adv!)
            (case (int c)
              100 [:ranges digit-ranges]
              68 [:ranges (complement-ranges digit-ranges)]
              119 [:ranges word-ranges]
              87 [:ranges (complement-ranges word-ranges)]
              115 [:ranges space-ranges]
              83 [:ranges (complement-ranges space-ranges)]
              98 (if in-class? [:cp 8] [:wordb])
              66 (if in-class? [:cp 66] [:nwordb])
              110 [:cp 10]
              114 [:cp 13]
              116 [:cp 9]
              102 [:cp 12]
              118 [:cp 11]
              48 [:cp 0]
              120 (if-let [v (hex-at @pos 2)]
                    (do (vswap! pos + 2) [:cp v])
                    [:cp 120])
              117 (if-let [v (hex-at @pos 4)]
                    (do (vswap! pos + 4)
                        (if (and (<= 0xD800 v 0xDBFF) (== (cur) 92) (== (at 1) 117))
                          (let [lo (hex-at (+ @pos 2) 4)]
                            (if (and lo (<= 0xDC00 lo 0xDFFF))
                              (do (vswap! pos + 6)
                                  [:cp (+ 0x10000 (* (- v 0xD800) 0x400) (- lo 0xDC00))])
                              [:cp v]))
                          [:cp v]))
                    [:cp 117])
              99 (let [l (cur)]
                   (if (or (<= 65 l 90) (<= 97 l 122))
                     (do (adv!) [:cp (mod l 32)])
                     (do (vswap! pos dec) [:cp 92])))   ; `\c` alone: a literal backslash
              [:cp c])))
        ;; pos is just after `[`
        parse-class
        (fn []
          (let [negate? (when (== (cur) 94) (adv!) true)
                class-atom (fn []
                             (let [c (cur)]
                               (when (neg? c) (err "unterminated character class"))
                               (adv!)
                               (if (== c 92) (parse-escape true) [:cp c])))]
            (loop [acc []]
              (let [c (cur)]
                (cond
                  (neg? c) (err "unterminated character class")
                  (== c 93) (do (adv!)
                                [:class (if negate? (complement-ranges acc) (normalize-ranges acc))])
                  :else
                  (let [a (class-atom)]
                    (if (and (== (cur) 45) (not= (at 1) 93) (not= (at 1) -1))
                      (do (adv!)
                          (let [b (class-atom)]
                            (if (and (= :cp (first a)) (= :cp (first b)))
                              (do (when (> (second a) (second b)) (err "range out of order"))
                                  (recur (conj acc [(second a) (second b)])))
                              ;; a class escape at either end: `-` is literal
                              (recur (-> acc (into (atom-ranges a)) (conj [45 45]) (into (atom-ranges b)))))))
                      (recur (into acc (atom-ranges a))))))))))
        ;; pos is at `{`: returns [min max] and advances when a well-formed
        ;; quantifier follows, otherwise nil (the `{` is then a literal).
        try-braces
        (fn []
          (let [read-int (fn [from]
                           (loop [i from, v nil]
                             (let [c (if (< i n) (aget cps i) -1)]
                               (if (<= 48 c 57)
                                 (recur (inc i) (+ (* (or v 0) 10) (- c 48)))
                                 [v i]))))
                [lo i] (read-int (inc @pos))
                c (if (< i n) (aget cps i) -1)]
            (when lo
              (cond
                (== c 125) (do (vreset! pos (inc i)) [lo lo])
                (== c 44) (let [[hi j] (read-int (inc i))]
                            (when (and (< j n) (== (aget cps j) 125))
                              (vreset! pos (inc j))
                              (when (and hi (< hi lo)) (err "numbers out of order in {} quantifier"))
                              [lo hi]))
                :else nil))))]
    (letfn [(parse-atom []
              (let [c (cur)]
                (case (int c)
                  94 (do (adv!) [:bol])
                  36 (do (adv!) [:eol])
                  46 (do (adv!) [:any])
                  40 (do (adv!)
                         (when (== (cur) 63)
                           (if (== (at 1) 58) (vswap! pos + 2) (err "unsupported group syntax")))
                         (let [d (parse-disjunction)]
                           (when-not (== (cur) 41) (err "missing )"))
                           (adv!)
                           d))
                  91 (do (adv!) (parse-class))
                  92 (do (adv!)
                         (let [e (parse-escape false)]
                           (case (first e)
                             :cp [:char (second e)]
                             :ranges [:class (normalize-ranges (second e))]
                             e)))
                  (42 43 63) (err "nothing to repeat")
                  (do (adv!) [:char c]))))
            (parse-term []
              (let [a (parse-atom)
                    q (case (int (cur))
                        42 (do (adv!) [0 nil])
                        43 (do (adv!) [1 nil])
                        63 (do (adv!) [0 1])
                        123 (try-braces)
                        nil)]
                (if q
                  (let [lazy? (when (== (cur) 63) (adv!) true)]
                    [:rep a (first q) (second q) (not lazy?)])
                  a)))
            (parse-alternative []
              (loop [items []]
                (let [c (cur)]
                  (if (or (neg? c) (== c 124) (== c 41))
                    (case (count items) 0 [:empty] 1 (first items) [:seq items])
                    (recur (conj items (parse-term)))))))
            (parse-disjunction []
              (loop [alts [(parse-alternative)]]
                (if (== (cur) 124)
                  (do (adv!) (recur (conj alts (parse-alternative))))
                  (if (== 1 (count alts)) (first alts) [:alt alts]))))]
      (let [tree (parse-disjunction)]
        (when (< @pos n) (err "unmatched )"))
        tree))))

;; ---------------------------------------------------------------------------
;; Compiler: syntax tree -> NFA program
;;
;; Instruction opcodes (parallel arrays op / x / y / cls):
;;   0 CHAR x=cp      1 ANY (not a line terminator)   2 CLASS cls=ranges array
;;   3 SPLIT x y      4 JMP x      5 ASSERT x=kind (0 bol 1 eol 2 wordb 3 nwordb)
;;   6 MATCH

(def ^:private line-terminator-array (ranges->array line-terminators))

(defn- emit-tree
  "Appends instructions for `node` to the transient vector `prog` (a volatile
  holding a vector of instruction vectors). Counted repetition is expanded."
  [prog node]
  (let [pc (fn [] (count @prog))
        emit! (fn [ins] (vswap! prog conj ins) (dec (count @prog)))
        patch! (fn [i ins] (vswap! prog assoc i ins))]
    (letfn [(emit-node [node]
              (case (first node)
                :empty nil
                :char (emit! [0 (second node) 0 nil])
                :any (emit! [1 0 0 nil])
                :class (emit! [2 0 0 (ranges->array (second node))])
                :bol (emit! [5 0 0 nil])
                :eol (emit! [5 1 0 nil])
                :wordb (emit! [5 2 0 nil])
                :nwordb (emit! [5 3 0 nil])
                :seq (doseq [c (second node)] (emit-node c))
                :alt (let [alts (second node)
                           jumps (volatile! [])]
                       (doseq [[i a] (map-indexed vector alts)]
                         (if (< i (dec (count alts)))
                           (let [split (emit! [3 0 0 nil])]
                             (emit-node a)
                             (vswap! jumps conj (emit! [4 0 0 nil]))
                             (patch! split [3 (inc split) (pc) nil]))
                           (emit-node a)))
                       (doseq [j @jumps] (patch! j [4 (pc) 0 nil])))
                :rep (let [[_ sub lo hi greedy?] node]
                       (dotimes [_ lo] (emit-node sub))
                       (if (nil? hi)
                         (let [split (emit! [3 0 0 nil])]
                           (emit-node sub)
                           (emit! [4 split 0 nil])
                           (patch! split (if greedy? [3 (inc split) (pc) nil] [3 (pc) (inc split) nil])))
                         (let [splits (vec (for [_ (range (- hi lo))]
                                             (let [s (emit! [3 0 0 nil])]
                                               (emit-node sub)
                                               s)))
                               end (pc)]
                           (doseq [s splits]
                             (patch! s (if greedy? [3 (inc s) end nil] [3 end (inc s) nil])))))))) ]
      (emit-node node))))

(defrecord Program [^ints op ^ints x ^ints y cls])

(defn compile-pattern
  "Compiles the regular expression `pattern` into a program usable with
  [[search?]]. Throws `ex-info` (`:type ::syntax-error`) when the pattern is
  invalid or uses unsupported syntax."
  [^String pattern]
  (let [prog (volatile! [])
        tree (parse pattern)]
    (emit-tree prog tree)
    (vswap! prog conj [6 0 0 nil])
    (let [p @prog
          cnt (count p)
          op (int-array cnt) x (int-array cnt) y (int-array cnt)
          cls (object-array cnt)]
      (dotimes [i cnt]
        (let [[o a b c] (nth p i)]
          (aset op i (int o)) (aset x i (int a)) (aset y i (int b)) (aset cls i c)))
      (->Program op x y cls))))

;; ---------------------------------------------------------------------------
;; Matcher: Thompson simulation over all start positions

(defn- word-cp? [^long c]
  (or (<= 48 c 57) (<= 65 c 90) (== c 95) (<= 97 c 122)))

(defn search?
  "True when the compiled `program` (see [[compile-pattern]]) matches
  somewhere in the string `s`. O(P*L)."
  [^Program program ^String s]
  (let [^ints subject (.toArray (.codePoints s))
        n (alength subject)
        ^ints op (.op program) ^ints x (.x program) ^ints y (.y program)
        ^objects cls (.cls program)
        plen (alength op)
        ;; thread lists and the per-step "already added" marks
        clist (int-array plen) nlist (int-array plen)
        mark (int-array plen)
        stack (int-array (inc (* 2 plen)))]
    (Arrays/fill mark -1)
    ;; `add` adds the epsilon-closure of `pc0` at subject position `i` to the
    ;; list `lst` (of consuming states) and returns the new list length, or -1
    ;; when MATCH is reachable.
    (let [add (fn [^ints lst len pc0 i gen]
                (aset stack 0 (int pc0))
                (loop [sp 1, len len]
                  (if (zero? sp)
                    len
                    (let [sp (dec sp)
                          pc (aget stack sp)]
                      (if (== (aget mark pc) gen)
                        (recur sp len)
                        (do
                          (aset mark pc (int gen))
                          (case (aget op pc)
                            4 (do (aset stack sp (aget x pc)) (recur (inc sp) len))
                            3 (do (aset stack sp (aget y pc))
                                  (aset stack (inc sp) (aget x pc))
                                  (recur (+ sp 2) len))
                            5 (let [ok (case (aget x pc)
                                         0 (zero? i)
                                         1 (== i n)
                                         (let [a (and (> i 0) (word-cp? (aget subject (dec i))))
                                               b (and (< i n) (word-cp? (aget subject i)))]
                                           (if (== (aget x pc) 2) (not= a b) (= a b))))]
                                (if ok
                                  (do (aset stack sp (int (inc pc))) (recur (inc sp) len))
                                  (recur sp len)))
                            6 -1
                            (do (aset lst len (int pc)) (recur sp (inc len))))))))))]
      ;; gen increases with every (position, list) pair so marks stay valid
      (loop [i 0, ^ints cur clist, ^ints nxt nlist, clen 0, gen 0]
        ;; seed a new thread starting at position i, joining the current list
        (let [clen (long (add cur clen 0 i gen))]
          (if (== clen -1)
            true
            (if (>= i n)
              false
              (let [c (aget subject i)
                    gen2 (inc gen)
                    nlen (loop [k 0, nlen 0]
                           (if (or (>= k clen) (== nlen -1))
                             nlen
                             (let [pc (aget cur k)
                                   hit (case (aget op pc)
                                         0 (== c (aget x pc))
                                         1 (not (in-ranges? line-terminator-array c))
                                         2 (in-ranges? ^longs (aget cls pc) c)
                                         false)]
                               (recur (inc k)
                                      (if hit (long (add nxt nlen (inc pc) (inc i) gen2)) nlen)))))]
                (if (== nlen -1)
                  true
                  (recur (inc i) nxt cur (long nlen) gen2))))))))))
