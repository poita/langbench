(ns commonmark.blocks
  "Phase 1 of the conversion: the block structure.

  The document is read line by line. For each line the chain of open blocks is
  matched against the start of the line, new blocks are opened, and the rest of
  the line is added to the innermost open leaf block (see Appendix A of the
  CommonMark specification).

  [[parse-blocks]] returns an immutable tree of maps. Every node has a `:type`:

  | `:type`          | other keys                                           |
  |------------------|------------------------------------------------------|
  | `:document`      | `:children`                                          |
  | `:block-quote`   | `:children`                                          |
  | `:list`          | `:children` (items), `:ordered?`, `:start`, `:tight?`|
  | `:list-item`     | `:children`                                          |
  | `:paragraph`     | `:content` (raw text)                                |
  | `:heading`       | `:level`, `:content` (raw text)                      |
  | `:thematic-break`|                                                      |
  | `:code-block`    | `:info`, `:literal`                                  |"
  (:require [commonmark.text :as t :refer [ch char-at]]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; The position within the current line
;; ---------------------------------------------------------------------------

(def ^:private ^:const tab-stop 4)

(defrecord Cursor [line ^long offset ^long column ptab])

(defrecord Look [^long offset ^long column ^long indent ^long ch])

(defn- look
  "Where the next non-space/tab character is, relative to cursor `c`. `:ch` is
  -1 at the end of the line (the line is *blank at this point*)."
  ^Look [^Cursor c]
  (let [^String line (.line c)
        n (.length line)
        col0 (.column c)]
    (loop [o (.offset c) col col0]
      (let [x (if (< o n) (long (int (.charAt line (int o)))) -1)]
        (cond
          (== x 32) (recur (inc o) (inc col))
          (== x 9) (recur (inc o) (+ col (- tab-stop (rem col tab-stop))))
          :else (->Look o col (- col col0) x))))))

(defn- advance-columns
  "Consume `n` columns of whitespace/characters; a tab may be partially consumed."
  ^commonmark.blocks.Cursor [^Cursor c ^long n]
  (let [^String line (.line c)
        len (.length line)]
    (loop [o (.offset c) col (.column c) ptab (.ptab c) k n]
      (if (and (pos? k) (< o len))
        (if (== (char-at line o) (ch \tab))
          (let [to-tab (- tab-stop (rem col tab-stop))]
            (if (> to-tab k)
              (recur o (+ col k) true 0)
              (recur (inc o) (+ col to-tab) false (- k to-tab))))
          (recur (inc o) (inc col) false (dec k)))
        (->Cursor line o col ptab)))))

(defn- advance-chars
  "Consume `n` characters (a tab counts as one character but advances the
  column to the next tab stop)."
  ^commonmark.blocks.Cursor [^Cursor c ^long n]
  (let [^String line (.line c)
        len (.length line)]
    (loop [o (.offset c) col (.column c) ptab (.ptab c) k n]
      (if (and (pos? k) (< o len))
        (if (== (char-at line o) (ch \tab))
          (recur (inc o) (+ col (- tab-stop (rem col tab-stop))) false (dec k))
          (recur (inc o) (inc col) false (dec k)))
        (->Cursor line o col ptab)))))

(defn- advance-to
  "Advance over spaces and tabs up to the offset of `lk`."
  ^commonmark.blocks.Cursor [^Cursor c ^Look lk]
  (advance-chars c (- (.offset lk) (.offset c))))

(defn- rest-of-line
  "The text from the cursor to the end of the line; a partially consumed tab
  contributes the columns that remain of it, as spaces."
  ^String [^Cursor c]
  (let [^String line (.line c)
        o (.offset c)]
    (if (.ptab c)
      (let [pad (- tab-stop (rem (.column c) tab-stop))]
        (str (apply str (repeat pad \space)) (.substring line (int (inc o)))))
      (.substring line (int o)))))

;; ---------------------------------------------------------------------------
;; Mutable blocks used while parsing
;; ---------------------------------------------------------------------------

;; A block under construction is a volatile holding a map. The keys common to
;; all blocks are: :type, :parent, :children (vector), :open?, :last-line-blank?,
;; :checked? (memo of `ends-with-blank-line?`), :start-line and :content (a
;; StringBuilder, for blocks that accept lines).

(defn- new-block
  [type parent line-no extra]
  (volatile! (merge {:type type
                     :parent parent
                     :children []
                     :open? true
                     :last-line-blank? false
                     :checked? false
                     :start-line line-no}
                    extra)))

(defn- bget [b k] (get @b k))
(defn- bset! [b k v] (vswap! b assoc k v) v)
(defn- btype [b] (:type @b))
(defn- last-child [b] (peek (:children @b)))
(defn- open-child [b] (when-let [c (last-child b)] (when (:open? @c) c)))

(defn- can-contain? [parent type]
  (case (btype parent)
    (:document :block-quote :list-item) (not= type :list-item)
    :list (= type :list-item)
    false))

(defn- accepts-lines? [type]
  (contains? #{:paragraph :heading :code-block} type))

(defn- add-line!
  "Append the rest of the line at cursor `c`, plus a newline, to block `b`."
  [b ^Cursor c]
  (.append ^StringBuilder (:content @b) (rest-of-line c))
  (.append ^StringBuilder (:content @b) \newline))

(defn- ends-with-blank-line?
  "Whether the block ends with a blank line: for a list or list item with
  children, whether its last child does; otherwise the block's own flag. As in
  cmark the answer is memoised: a block that has been examined once answers
  with its own flag from then on, without recursing."
  [b]
  (loop [cur b]
    (let [m @cur]
      (if (:checked? m)
        (:last-line-blank? m)
        (do (bset! cur :checked? true)
            (if (and (#{:list :list-item} (:type m)) (seq (:children m)))
              (recur (last-child cur))
              (:last-line-blank? m)))))))

(defn- list-tight?
  [list-block]
  (let [items (:children @list-block)
        n (count items)]
    (loop [i 0]
      (if (== i n)
        true
        (let [item (nth items i)
              last-item? (== i (dec n))]
          (if (and (not last-item?) (:last-line-blank? @item))
            false
            (let [kids (:children @item)
                  k (count kids)]
              (if (loop [j 0]
                    (when (< j k)
                      (if (and (or (not last-item?) (< j (dec k)))
                               (ends-with-blank-line? (nth kids j)))
                        true
                        (recur (inc j)))))
                false
                (recur (inc i))))))))))

(defn- remove-trailing-blank-lines
  "For indented code: drop trailing blank lines, keeping the final line's own
  trailing whitespace, and end the content with a newline."
  ^String [^String s]
  (let [e (loop [i (dec (.length s))]
            (if (and (>= i 0) (let [c (char-at s i)] (or (t/space-or-tab? c) (== c 10))))
              (recur (dec i))
              i))]
    (if (neg? e)
      "\n"
      (let [nl (.indexOf s "\n" (int e))]
        (str (if (neg? nl) s (.substring s 0 nl)) "\n")))))

(defn- finalize-block!
  "Close `b` (without closing descendants) and return its parent."
  [b]
  (when (:open? @b)
    (bset! b :open? false)
    (case (btype b)
      :list (bset! b :tight? (list-tight? b))
      :code-block
      (let [content (str (:content @b))]
        (if (:fenced? @b)
          (let [nl (.indexOf content "\n")
                info (if (neg? nl) content (.substring content 0 nl))]
            (bset! b :info (t/clean-string (t/trim-ws (t/decode-entities info))))
            (bset! b :literal (if (neg? nl) "" (.substring content (inc nl)))))
          (bset! b :literal (remove-trailing-blank-lines content))))
      nil))
  (:parent @b))

(defn- add-child!
  "Add a new block of `type` below `parent`, closing blocks that cannot
  contain it."
  [parent type line-no extra]
  (let [parent (loop [p parent]
                 (if (can-contain? p type) p (recur (finalize-block! p))))
        child (new-block type parent line-no
                         (cond-> extra
                           (accepts-lines? type) (assoc :content (StringBuilder.))))]
    (vswap! parent update :children conj child)
    child))

;; ---------------------------------------------------------------------------
;; Block start scanners (they work on the line from the first non-space)
;; ---------------------------------------------------------------------------

(defn- atx-heading-level
  "Level of an ATX heading start at `o`, or 0. Returns [level end-after-spaces]."
  [^String line ^long o]
  (let [hashes (loop [i o] (if (== (char-at line i) (ch \#)) (recur (inc i)) i))
        level (- hashes o)]
    (when (and (<= 1 level 6)
               (let [c (char-at line hashes)] (or (== c -1) (t/space-or-tab? c))))
      [level (loop [i hashes] (if (t/space-or-tab? (char-at line i)) (recur (inc i)) i))])))

(defn- fence-start
  "Opening code fence at `o`: [char length] or nil."
  [^String line ^long o]
  (let [c (char-at line o)]
    (when (or (== c (ch \`)) (== c (ch \~)))
      (let [e (loop [i o] (if (== (char-at line i) c) (recur (inc i)) i))
            len (- e o)]
        (when (and (>= len 3)
                   (or (== c (ch \~)) (neg? (.indexOf line "`" (int e)))))
          [c len])))))

(defn- closing-fence?
  [^String line ^long o fence-char ^long fence-len]
  (let [e (loop [i o] (if (== (char-at line i) (long fence-char)) (recur (inc i)) i))]
    (and (>= (- e o) fence-len)
         (loop [i e]
           (let [c (char-at line i)]
             (cond (== c -1) true
                   (t/space-or-tab? c) (recur (inc i))
                   :else false))))))

(defn- setext-level
  "1 or 2 when the rest of the line (from `o`) is a setext underline, else nil."
  [^String line ^long o]
  (let [c (char-at line o)]
    (when (or (== c (ch \=)) (== c (ch \-)))
      (let [e (loop [i o] (if (== (char-at line i) c) (recur (inc i)) i))]
        (when (loop [i e]
                (let [x (char-at line i)]
                  (cond (== x -1) true
                        (t/space-or-tab? x) (recur (inc i))
                        :else false)))
          (if (== c (ch \=)) 1 2))))))

(defn- thematic-break?
  [^String line ^long o]
  (let [c (char-at line o)]
    (when (or (== c (ch \*)) (== c (ch \_)) (== c (ch \-)))
      (loop [i o n 0]
        (let [x (char-at line i)]
          (cond (== x c) (recur (inc i) (inc n))
                (t/space-or-tab? x) (recur (inc i) n)
                (== x -1) (>= n 3)
                :else false))))))

(defn- parse-list-marker
  "A list marker at `pos`. Returns a map {:ordered? :char :start :width} or nil.
  When `interrupts?` the marker must be followed by content and an ordered
  marker must be numbered 1."
  [^String line ^long pos interrupts?]
  (let [eol-or-ws? (fn [^long c] (or (== c -1) (t/ws? c)))
        content-follows? (fn [^long from]
                           (loop [i from]
                             (let [c (char-at line i)]
                               (cond (t/space-or-tab? c) (recur (inc i))
                                     (== c -1) false
                                     :else true))))
        c (char-at line pos)]
    (cond
      (or (== c (ch \*)) (== c (ch \-)) (== c (ch \+)))
      (when (and (eol-or-ws? (char-at line (inc pos)))
                 (or (not interrupts?) (content-follows? (inc pos))))
        {:ordered? false :char c :start 0 :width 1})

      (t/digit? c)
      (let [end (loop [i (inc pos)]
                  (if (and (< (- i pos) 9) (t/digit? (char-at line i))) (recur (inc i)) i))
            start (Long/parseLong (.substring line (int pos) (int end)))
            d (char-at line end)]
        (when (and (or (== d (ch \.)) (== d (ch \))))
                   (or (not interrupts?) (== start 1))
                   (eol-or-ws? (char-at line (inc end)))
                   (or (not interrupts?) (content-follows? (inc end))))
          {:ordered? true :char d :start start :width (inc (- end pos))}))

      :else nil)))

(defn- lists-match? [list-block marker]
  (let [m @list-block]
    (and (= (:ordered? m) (:ordered? marker))
         (== (long (:char m)) (long (:char marker))))))

;; ---------------------------------------------------------------------------
;; Step 1: continue the open blocks
;; ---------------------------------------------------------------------------

(defn- continue-block
  "Try to match open block `b` against the line at cursor `c`. Returns the
  advanced cursor, nil if `b` does not continue, or :closed when `b` was a
  fenced code block closed by this line."
  [b ^Cursor c]
  (let [m @b
        lk (look c)]
    (case (:type m)
      :block-quote
      (when (and (<= (.indent lk) 3) (== (.ch lk) (ch \>)))
        (let [^Cursor c1 (advance-chars c (- (inc (.offset lk)) (.offset c)))]
          (if (t/space-or-tab? (char-at (.line c1) (.offset c1)))
            (advance-columns c1 1)
            c1)))

      :list-item
      (cond
        (>= (.indent lk) (+ (long (:marker-offset m)) (long (:padding m))))
        (advance-columns c (+ (long (:marker-offset m)) (long (:padding m))))

        (and (== (.ch lk) -1) (seq (:children m)))
        (advance-to c lk)

        :else nil)

      :list c

      :code-block
      (if (:fenced? m)
        (if (and (<= (.indent lk) 3)
                 (closing-fence? (.line c) (.offset lk) (:fence-char m) (:fence-length m)))
          :closed
          (loop [cc c k (long (:fence-offset m))]
            (let [x (char-at (.line cc) (.offset cc))]
              (if (and (pos? k) (t/space-or-tab? x))
                (recur (advance-columns cc 1) (dec k))
                cc))))
        (cond
          (>= (.indent lk) 4) (advance-columns c 4)
          (== (.ch lk) -1) (advance-to c lk)
          :else nil))

      :heading nil
      :thematic-break c
      :paragraph (when-not (== (.ch lk) -1) c)
      c)))

;; ---------------------------------------------------------------------------
;; Steps 2 and 3
;; ---------------------------------------------------------------------------

(defn- chop-closing-hashes
  "Remove the optional closing sequence of an ATX heading line."
  ^String [^String s]
  (let [s (t/rtrim-ws s)
        n (.length s)
        e (loop [i (dec n)] (if (and (>= i 0) (== (char-at s i) (ch \#))) (recur (dec i)) i))]
    (if (and (< e (dec n)) (or (neg? e) (t/space-or-tab? (char-at s e))))
      (t/rtrim-ws (.substring s 0 (int (inc e))))
      s)))

(defn- open-new-blocks
  "Step 2. Returns [container cursor] where container is the innermost block
  the rest of the line belongs to."
  [last-matched ^Cursor cur tip line-no]
  (loop [container last-matched
         cur cur
         maybe-lazy? (if (= :paragraph (btype tip)) true false)]
    (if (= :code-block (btype container))
      [container cur]
      (let [lk (look cur)
            indented? (>= (.indent lk) 4)
            c (.ch lk)
            ^String line (.line cur)
            nso (.offset lk)
            ctype (btype container)]
        (cond
          ;; 1. block quote
          (and (not indented?) (== c (ch \>)))
          (let [^Cursor c1 (advance-chars cur (- (inc nso) (.offset cur)))
                c2 (if (t/space-or-tab? (char-at line (.offset c1))) (advance-columns c1 1) c1)]
            (recur (add-child! container :block-quote line-no nil) c2 false))

          ;; 2. ATX heading
          (and (not indented?) (atx-heading-level line nso))
          (let [[level end] (atx-heading-level line nso)]
            [(add-child! container :heading line-no {:level level})
             (advance-chars cur (- (long end) (.offset cur)))])

          ;; 3. fenced code
          (and (not indented?) (fence-start line nso))
          (let [[fc len] (fence-start line nso)]
            [(add-child! container :code-block line-no
                         {:fenced? true :fence-char fc :fence-length len
                          :fence-offset (- nso (.offset cur))})
             (advance-chars cur (- (+ nso (long len)) (.offset cur)))])

          ;; 4. setext underline
          (and (not indented?) (= ctype :paragraph) (setext-level line nso))
          (let [level (setext-level line nso)]
            (vswap! container assoc :type :heading :level level)
            [container (advance-chars cur (- (.length line) (.offset cur)))])

          ;; 5. thematic break
          (and (not indented?) (thematic-break? line nso))
          [(add-child! container :thematic-break line-no nil)
           (advance-chars cur (- (.length line) (.offset cur)))]

          ;; 6. list item
          (and (< (.indent lk) 4)
               (parse-list-marker line nso (= ctype :paragraph)))
          (let [marker (parse-list-marker line nso (= ctype :paragraph))
                w (long (:width marker))
                ^Cursor after (advance-chars cur (- (+ nso w) (.offset cur)))
                ;; the whitespace after the marker (counting stops past 5 columns)
                ^Cursor ws (loop [cc after]
                     (if (and (<= (- (.column cc) (.column after)) 5)
                              (t/space-or-tab? (char-at line (.offset cc))))
                       (recur (advance-columns cc 1))
                       cc))
                n (- (.column ws) (.column after))
                blank-item? (== (char-at line (.offset ws)) -1)
                [padding cur2] (if (or (zero? n) (>= n 5) blank-item?)
                                 [(inc w) (if (pos? n) (advance-columns after 1) after)]
                                 [(+ w n) ws])
                list-block (if (and (= ctype :list) (lists-match? container marker))
                             container
                             (add-child! container :list line-no
                                         {:ordered? (:ordered? marker)
                                          :char (:char marker)
                                          :start (:start marker)}))
                item (add-child! list-block :list-item line-no
                                 {:marker-offset (.indent lk) :padding padding})]
            (recur item cur2 false))

          ;; 7. indented code
          (and indented? (not maybe-lazy?) (not= c -1))
          [(add-child! container :code-block line-no {:fenced? false})
           (advance-columns cur 4)]

          :else [container cur])))))

(defn- update-blank-flags!
  "The \"last line blank\" bookkeeping that decides list tightness."
  [container blank? line-no]
  (let [ctype (btype container)]
    (when (and blank? (last-child container))
      (bset! (last-child container) :last-line-blank? true))
    (bset! container :last-line-blank?
           (boolean (and blank?
                         (not (#{:block-quote :heading :thematic-break} ctype))
                         (not (and (= ctype :code-block) (:fenced? @container)))
                         (not (and (= ctype :list-item)
                                   (empty? (:children @container))
                                   (== (long (:start-line @container)) (long line-no)))))))
    (loop [p (:parent @container)]
      (when p
        (bset! p :last-line-blank? false)
        (recur (:parent @p))))))

(defn- process-line!
  "Process one line (without its newline). `tip` is a volatile holding the
  innermost open block."
  [doc tip ^String line line-no]
  (let [;; Step 1: continue the open blocks
        [last-matched all-matched? ^Cursor cur]
        (loop [container doc cur (->Cursor line 0 0 false)]
          (if-let [child (open-child container)]
            (let [r (continue-block child cur)]
              (cond (nil? r) [container false cur]
                    (identical? r :closed) [child :closed cur]
                    :else (recur child r)))
            [container true cur]))]
    (if (identical? all-matched? :closed)
      ;; a closing fence ends the code block and the line
      (vreset! tip (finalize-block! last-matched))
      (let [old-tip @tip
            ;; Step 2: open new blocks
            [container ^Cursor cur] (open-new-blocks last-matched cur old-tip line-no)
            lk (look cur)
            blank? (== (.ch lk) -1)
            ctype (btype container)]
        ;; Step 3: add the text of the line
        (update-blank-flags! container blank? line-no)
        (if (and (not all-matched?)
                 (identical? container last-matched)
                 (not blank?)
                 (= :paragraph (btype old-tip)))
          (add-line! old-tip cur)               ; lazy continuation
          (do
            (loop [t old-tip]
              (when-not (identical? t last-matched)
                (recur (finalize-block! t))))
            (cond
              (= ctype :code-block)
              (do (add-line! container cur)
                  (vreset! tip container))

              blank?
              (vreset! tip container)

              (= ctype :heading)
              (let [text (chop-closing-hashes (rest-of-line (advance-to cur lk)))]
                (.append ^StringBuilder (:content @container) text)
                (.append ^StringBuilder (:content @container) \newline)
                (vreset! tip container))

              (= ctype :paragraph)
              (do (add-line! container (advance-to cur lk))
                  (vreset! tip container))

              :else
              (let [para (add-child! container :paragraph line-no nil)]
                (add-line! para (advance-to cur lk))
                (vreset! tip para)))))))))

;; ---------------------------------------------------------------------------
;; Public entry point
;; ---------------------------------------------------------------------------

(defn- freeze
  "Convert a finished mutable block into the immutable tree described in the
  namespace docstring."
  [b]
  (let [m @b]
    (case (:type m)
      (:document :block-quote :list-item)
      {:type (:type m) :children (mapv freeze (:children m))}

      :list
      {:type :list
       :ordered? (:ordered? m)
       :start (:start m)
       :tight? (:tight? m)
       :children (mapv freeze (:children m))}

      :paragraph {:type :paragraph :content (str (:content m))}
      :heading {:type :heading :level (:level m) :content (str (:content m))}
      :thematic-break {:type :thematic-break}
      :code-block {:type :code-block
                   :info (or (:info m) "")
                   :literal (:literal m)})))

(defn- split-lines
  "Split on LF; a trailing LF does not start another line."
  [^String s]
  (let [n (.length s)]
    (loop [start 0 acc (transient [])]
      (if (>= start n)
        (persistent! acc)
        (let [nl (.indexOf s "\n" (int start))]
          (if (neg? nl)
            (persistent! (conj! acc (.substring s (int start))))
            (recur (inc nl) (conj! acc (.substring s (int start) (int nl))))))))))

(defn parse-blocks
  "Parse the Markdown text `input` into the block tree described in the
  namespace docstring. Paragraphs and headings keep their raw `:content`; see
  `commonmark.inlines` for the second phase."
  [^String input]
  (let [doc (new-block :document nil 0 nil)
        tip (volatile! doc)]
    (loop [lines (seq (split-lines input)) line-no 1]
      (when lines
        (process-line! doc tip (first lines) line-no)
        (recur (next lines) (inc line-no))))
    (loop [b @tip]
      (when b (recur (finalize-block! b))))
    (freeze doc)))
