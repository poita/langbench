(ns sitegen.markdown.block
  "Phase 1 of the Markdown conversion: a line-driven block parser in the style
  of cmark.  Each line is matched against the chain of open blocks, new blocks
  are opened, and the rest of the line is added to the innermost open leaf.
  The result is a tree of block nodes whose paragraphs and headings still hold
  their raw text (see `sitegen.markdown.inline` for phase 2)."
  (:require [sitegen.markdown.node :as nd]
            [sitegen.markdown.text :as t]
            [sitegen.mutable :refer [defmutable]]))

(set! *warn-on-reflection* true)

;; The parser state.  `offset`/`column` is the cursor in the current line
;; (`column` has tabs expanded to multiples of 4), `ptab` says that the tab at
;; `offset` has been partially consumed, and `first-nonspace`, `fn-column`,
;; `indent` and `blank` describe the next non-space character (see
;; `find-first-nonspace!`).
(defmutable Parser "p-"
  [root tip line-no all-matched
   offset column ptab first-nonspace fn-column indent blank])

(defn- peek-at
  "The character code at index `i` of `line`, or 0 past the end."
  ^long [^String line ^long i]
  (if (< i (.length line)) (long (int (.charAt line i))) 0))

(defn- space-or-tab? [c] (let [c (int c)] (or (== c 32) (== c 9))))

(defn- advance!
  "Moves the cursor forward by `n` columns (`columns?` true; a tab may be
  consumed partially) or by `n` characters (`columns?` false)."
  [p ^String line ^long n columns?]
  (loop [n n]
    (let [off (long (p-offset p))
          ch (peek-at line off)]
      (when (and (pos? n) (not (zero? ch)))
        (let [col (long (p-column p))]
          (if (== ch 9)
            (let [to-tab (- 4 (rem col 4))]
              (if columns?
                (let [partial (> to-tab n)
                      adv (min n to-tab)]
                  (p-ptab! p partial)
                  (p-column! p (+ col adv))
                  (p-offset! p (if partial off (inc off)))
                  (recur (- n adv)))
                (do (p-ptab! p false)
                    (p-column! p (+ col to-tab))
                    (p-offset! p (inc off))
                    (recur (dec n)))))
            (do (p-ptab! p false)
                (p-column! p (inc col))
                (p-offset! p (inc off))
                (recur (dec n)))))))))

(defn- find-first-nonspace!
  "Locates the first character at or after the cursor that is not a space or
  tab and records its index, its column, the indentation up to it and whether
  the rest of the line is blank."
  [p ^String line]
  (let [off (long (p-offset p))
        col (long (p-column p))]
    (loop [i off c col]
      (let [ch (peek-at line i)]
        (cond
          (== ch 32) (recur (inc i) (inc c))
          (== ch 9) (recur (inc i) (+ c (- 4 (rem c 4))))
          :else (do (p-first-nonspace! p i)
                    (p-fn-column! p c)
                    (p-indent! p (- c col))
                    (p-blank! p (zero? ch))))))))

(defn- rest-of-line
  "The text from the cursor to the end of the line; a partially consumed tab
  is replaced by the spaces that remain of it."
  ^String [p ^String line]
  (let [off (long (p-offset p))]
    (if (p-ptab p)
      (let [spaces (- 4 (rem (long (p-column p)) 4))]
        (str (apply str (repeat spaces \space)) (.substring line (inc off))))
      (if (>= off (.length line)) "" (.substring line off)))))

(defn- add-line!
  "Appends the rest of the line, then a newline, to the content of `node`."
  [p node ^String line]
  (let [^StringBuilder sb (nd/text node)]
    (.append sb (rest-of-line p line))
    (.append sb \newline)))

;; ---------------------------------------------------------------------------
;; Tree helpers

(defn- accepts-lines? [kind]
  (case kind (:paragraph :heading :code-block) true false))

(defn- can-contain? [parent-kind child-kind]
  (case parent-kind
    (:document :block-quote :item) (not= child-kind :item)
    :list (= child-kind :item)
    false))

(declare finalize!)

(defn- add-child!
  "Adds a new block of `kind` below `parent`, closing blocks upwards until one
  that can hold it is found."
  [p parent kind]
  (loop [parent parent]
    (if (can-contain? (nd/kind parent) kind)
      (let [child (nd/make kind)]
        (nd/open! child true)
        (when (accepts-lines? kind) (nd/text! child (StringBuilder.)))
        (nd/start-line! child (p-line-no p))
        (nd/append-child! parent child)
        child)
      (recur (finalize! p parent)))))

(defn- ends-with-blank-line?
  "cmark's memoised test whether a block ends with a blank line."
  [node]
  (loop [cur node]
    (cond
      (nil? cur) false
      (nd/checked cur) (boolean (nd/last-blank cur))
      (and (#{:list :item} (nd/kind cur)) (nd/last-child cur))
      (do (nd/checked! cur true) (recur (nd/last-child cur)))
      :else (do (nd/checked! cur true) (boolean (nd/last-blank cur))))))

(defn- list-tight? [list-node]
  (loop [item (nd/first-child list-node)]
    (if (nil? item)
      true
      (if (and (nd/last-blank item) (nd/next-sibling item))
        false
        (if (loop [sub (nd/first-child item)]
              (cond
                (nil? sub) true
                (and (or (nd/next-sibling item) (nd/next-sibling sub))
                     (ends-with-blank-line? sub)) false
                :else (recur (nd/next-sibling sub))))
          (recur (nd/next-sibling item))
          false)))))

(defn- strip-trailing-blank-lines
  "Indented code: drops trailing blank lines, keeping trailing spaces of the
  last non-blank line."
  ^String [^String s]
  (let [i (loop [i (dec (.length s))]
            (if (and (>= i 0) (let [c (.charAt s i)] (or (t/ws? c))))
              (recur (dec i))
              i))]
    (if (neg? i)
      ""
      (let [nl (.indexOf s (int \newline) (int i))]
        (if (neg? nl) s (.substring s 0 nl))))))

(defn- finalize!
  "Closes block `b`, doing the post-processing its kind needs.  Returns the
  parent."
  [p b]
  (nd/open! b false)
  (case (nd/kind b)
    :code-block
    (let [^StringBuilder sb (nd/text b)]
      (if (nd/fenced b)
        (let [s (.toString sb)
              nl (.indexOf s (int \newline))
              first-line (if (neg? nl) s (.substring s 0 nl))]
          (nd/info! b (t/unescape-backslashes (t/trim (t/decode-entities first-line))))
          (.delete sb 0 (int (if (neg? nl) (.length s) (inc nl)))))
        (let [s (strip-trailing-blank-lines (.toString sb))]
          (.setLength sb 0)
          (.append sb s)
          (.append sb \newline))))
    :list (nd/tight! b (list-tight? b))
    nil)
  (nd/parent b))

;; ---------------------------------------------------------------------------
;; Scanners (each looks only at the characters it consumes)

(defn- scan-atx-heading
  "Returns [level matched-length] when an ATX heading starts at `i`."
  [^String line ^long i]
  (when (== (peek-at line i) (int \#))
    (let [hashes (loop [j i] (if (== (peek-at line j) (int \#)) (recur (inc j)) (- j i)))]
      (when (<= 1 hashes 6)
        (let [after (+ i hashes)
              c (peek-at line after)]
          (cond
            (zero? c) [hashes hashes]
            (space-or-tab? c)
            (let [e (loop [j after] (if (space-or-tab? (peek-at line j)) (recur (inc j)) j))]
              [hashes (- e i)])
            :else nil))))))

(defn- scan-open-fence
  "Returns the length of the code fence starting at `i`, or nil."
  [^String line ^long i]
  (let [c (peek-at line i)]
    (when (or (== c (int \`)) (== c (int \~)))
      (let [e (loop [j i] (if (== (peek-at line j) c) (recur (inc j)) j))
            len (- e i)]
        (when (and (>= len 3)
                   (or (== c (int \~))
                       (neg? (.indexOf line (int \`) (int e)))))
          len)))))

(defn- scan-close-fence
  "Length of the run of fence character `c` at `i` when followed only by
  spaces and tabs, else 0."
  ^long [^String line ^long i ^long c]
  (let [e (loop [j i] (if (== (peek-at line j) c) (recur (inc j)) j))]
    (if (and (> e i)
             (loop [j e] (let [ch (peek-at line j)]
                           (cond (zero? ch) true (space-or-tab? ch) (recur (inc j)) :else false))))
      (- e i)
      0)))

(defn- scan-setext-underline
  "Returns 1 or 2 when the rest of the line from `i` is a setext underline."
  [^String line ^long i]
  (let [c (peek-at line i)]
    (when (or (== c (int \=)) (== c (int \-)))
      (let [e (loop [j i] (if (== (peek-at line j) c) (recur (inc j)) j))]
        (when (loop [j e] (let [ch (peek-at line j)]
                            (cond (zero? ch) true (space-or-tab? ch) (recur (inc j)) :else false)))
          (if (== c (int \=)) 1 2))))))

(defn- thematic-break? [^String line ^long i]
  (let [c (peek-at line i)]
    (when (or (== c (int \*)) (== c (int \-)) (== c (int \_)))
      (loop [j i n 0]
        (let [ch (peek-at line j)]
          (cond
            (== ch c) (recur (inc j) (inc n))
            (space-or-tab? ch) (recur (inc j) n)
            (zero? ch) (>= n 3)
            :else false))))))

(defn- parse-list-marker
  "Returns a map describing the list marker at `i`, or nil.  `:matched` is the
  marker's width in characters."
  [^String line ^long i interrupts-paragraph?]
  (let [c (peek-at line i)
        blank-after? (fn [^long j]
                       (zero? (peek-at line (loop [k j] (if (space-or-tab? (peek-at line k)) (recur (inc k)) k)))))
        space-char? (fn [^long ch] (or (zero? ch) (t/ws? ch)))]
    (cond
      (or (== c (int \*)) (== c (int \-)) (== c (int \+)))
      (when (and (space-char? (peek-at line (inc i)))
                 (not (and interrupts-paragraph? (blank-after? (inc i)))))
        {:matched 1 :ordered false :bullet (char c) :start 0})

      (t/ascii-digit? c)
      (let [e (loop [j i] (if (and (< (- j i) 9) (t/ascii-digit? (peek-at line j))) (recur (inc j)) j))
            start (Long/parseLong (.substring line (int i) (int e)))
            d (peek-at line e)]
        (when (and (or (== d (int \.)) (== d (int \))))
                   (space-char? (peek-at line (inc e)))
                   (not (and interrupts-paragraph?
                             (or (not= start 1) (blank-after? (inc e))))))
          {:matched (- (inc e) i) :ordered true :bullet (char d) :start start}))

      :else nil)))

;; ---------------------------------------------------------------------------
;; Step 1: continue open blocks

(defn- continue-block-quote? [p ^String line]
  (when (and (<= (long (p-indent p)) 3)
             (== (peek-at line (p-first-nonspace p)) (int \>)))
    (advance! p line (- (inc (long (p-first-nonspace p))) (long (p-offset p))) false)
    (when (space-or-tab? (peek-at line (p-offset p)))
      (advance! p line 1 true))
    true))

(defn- continue-item? [p ^String line item]
  (let [need (+ (long (nd/marker-offset item)) (long (nd/padding item)))]
    (cond
      (>= (long (p-indent p)) need) (do (advance! p line need true) true)
      (and (p-blank p) (nd/first-child item))
      (do (advance! p line (- (long (p-first-nonspace p)) (long (p-offset p))) false) true)
      :else false)))

(defn- continue-code-block
  "Returns :continue, :fail or :closed (a closing fence was found)."
  [p ^String line block]
  (if-not (nd/fenced block)
    (cond
      (>= (long (p-indent p)) 4) (do (advance! p line 4 true) :continue)
      (p-blank p) (do (advance! p line (- (long (p-first-nonspace p)) (long (p-offset p))) false) :continue)
      :else :fail)
    (let [fc (long (int (nd/fence-char block)))]
      (if (and (<= (long (p-indent p)) 3)
               (== (peek-at line (p-first-nonspace p)) fc)
               (>= (scan-close-fence line (p-first-nonspace p) fc) (long (nd/level block))))
        (do (finalize! p block)
            (p-tip! p (nd/parent block))
            :closed)
        (do (loop [i (long (nd/fence-offset block))]
              (when (and (pos? i) (space-or-tab? (peek-at line (p-offset p))))
                (advance! p line 1 true)
                (recur (dec i))))
            :continue)))))

(defn- check-open-blocks
  "Walks the chain of open blocks, consuming the prefix each requires.
  Returns the last block that matched, or nil when the line was a closing
  fence and is fully handled.  Sets `all-matched`."
  [p ^String line]
  (loop [container (p-root p)]
    (let [child (nd/last-child container)]
      (if (and child (nd/open child))
        (do
          (find-first-nonspace! p line)
          (let [r (case (nd/kind child)
                    :block-quote (if (continue-block-quote? p line) :continue :fail)
                    :item (if (continue-item? p line child) :continue :fail)
                    :code-block (continue-code-block p line child)
                    :heading :fail
                    :paragraph (if (p-blank p) :fail :continue)
                    :continue)]
            (case r
              :continue (recur child)
              :fail (do (p-all-matched! p false) container)
              :closed nil)))
        (do (p-all-matched! p true) container)))))

;; ---------------------------------------------------------------------------
;; Step 2: open new blocks

(defn- open-new-blocks
  "Opens the blocks that start at the cursor, below `container`.  Returns the
  innermost new container."
  [p ^String line container]
  (loop [container container
         maybe-lazy (Boolean/valueOf (= :paragraph (nd/kind (p-tip p))))]
    (if (= :code-block (nd/kind container))
      container
      (let [_ (find-first-nonspace! p line)
            indent (long (p-indent p))
            fs (long (p-first-nonspace p))
            indented (>= indent 4)
            c (peek-at line fs)
            kind (nd/kind container)
            ;; Returns the new container or nil when nothing starts here.
            new-container
            (cond
              ;; Block quote
              (and (not indented) (== c (int \>)))
              (do (advance! p line (- (inc fs) (long (p-offset p))) false)
                  (when (space-or-tab? (peek-at line (p-offset p)))
                    (advance! p line 1 true))
                  (add-child! p container :block-quote))

              ;; ATX heading
              (and (not indented) (scan-atx-heading line fs))
              (let [[level matched] (scan-atx-heading line fs)]
                (advance! p line (- (+ fs (long matched)) (long (p-offset p))) false)
                (doto (add-child! p container :heading)
                  (nd/level! level)))

              ;; Fenced code block
              (and (not indented) (scan-open-fence line fs))
              (let [len (scan-open-fence line fs)
                    block (add-child! p container :code-block)]
                (nd/fenced! block true)
                (nd/fence-char! block (char c))
                (nd/level! block len)
                (nd/fence-offset! block (- fs (long (p-offset p))))
                (advance! p line (- (+ fs (long len)) (long (p-offset p))) false)
                block)

              ;; Setext heading underline
              (and (not indented) (= kind :paragraph) (scan-setext-underline line fs))
              (let [level (scan-setext-underline line fs)]
                (nd/kind! container :heading)
                (nd/level! container level)
                (nd/setext! container true)
                (advance! p line (- (.length line) (long (p-offset p))) false)
                container)

              ;; Thematic break
              (and (not indented) (thematic-break? line fs))
              (let [block (add-child! p container :thematic-break)]
                (advance! p line (- (.length line) (long (p-offset p))) false)
                block)

              ;; List item
              (and (< indent 4) (parse-list-marker line fs (= kind :paragraph)))
              (let [{:keys [matched ordered bullet start]} (parse-list-marker line fs (= kind :paragraph))
                    matched (long matched)]
                (advance! p line (- (+ fs matched) (long (p-offset p))) false)
                (let [save-off (long (p-offset p))
                      save-col (long (p-column p))
                      save-ptab (p-ptab p)]
                  (loop []
                    (when (and (<= (- (long (p-column p)) save-col) 5)
                               (space-or-tab? (peek-at line (p-offset p))))
                      (advance! p line 1 true)
                      (recur)))
                  (let [i (- (long (p-column p)) save-col)
                        padding (if (or (>= i 5) (< i 1) (zero? (peek-at line (p-offset p))))
                                  (do (p-offset! p save-off)
                                      (p-column! p save-col)
                                      (p-ptab! p save-ptab)
                                      (when (> i 0) (advance! p line 1 true))
                                      (inc matched))
                                  (+ matched i))
                        list-node (if (and (= kind :list)
                                           (= (boolean ordered) (boolean (nd/ordered container)))
                                           (= bullet (nd/bullet container)))
                                    container
                                    (doto (add-child! p container :list)
                                      (nd/ordered! ordered)
                                      (nd/bullet! bullet)
                                      (nd/level! start)))
                        item (add-child! p list-node :item)]
                    (nd/marker-offset! item indent)
                    (nd/padding! item padding)
                    item)))

              ;; Indented code block
              (and indented (not maybe-lazy) (not (p-blank p)))
              (do (advance! p line 4 true)
                  (add-child! p container :code-block))

              :else nil)]
        (cond
          (nil? new-container) container
          (accepts-lines? (nd/kind new-container)) new-container
          :else (recur new-container false))))))

;; ---------------------------------------------------------------------------
;; Step 3: add the text of the line

(defn- chop-trailing-hashtags
  "ATX headings: removes the optional closing sequence of `#`s from the line."
  ^String [^String line]
  (let [line (t/rtrim line)
        orig (dec (.length line))
        n (loop [n orig] (if (and (>= n 0) (= (.charAt line n) \#)) (recur (dec n)) n))]
    (if (and (not= n orig) (>= n 0) (space-or-tab? (.charAt line n)))
      (t/rtrim (.substring line 0 n))
      line)))

(defn- add-text-to-container
  [p ^String line container last-matched]
  (find-first-nonspace! p line)
  (let [blank (p-blank p)
        kind (nd/kind container)]
    (when (and blank (nd/last-child container))
      (nd/last-blank! (nd/last-child container) true))
    (nd/last-blank! container
                    (boolean
                     (and blank
                          (not (#{:block-quote :heading :thematic-break} kind))
                          (not (and (= kind :code-block) (nd/fenced container)))
                          (not (and (= kind :item) (nil? (nd/first-child container))
                                    (== (long (nd/start-line container)) (long (p-line-no p))))))))
    (loop [tmp (nd/parent container)]
      (when tmp
        (nd/last-blank! tmp false)
        (recur (nd/parent tmp))))
    (let [tip (p-tip p)]
      (if (and (not (identical? tip last-matched))
               (identical? container last-matched)
               (not blank)
               (= :paragraph (nd/kind tip)))
        (add-line! p tip line)
        (do
          (loop []
            (when-not (identical? (p-tip p) last-matched)
              (p-tip! p (finalize! p (p-tip p)))
              (recur)))
          (let [container
                (cond
                  (= kind :code-block)
                  (do (add-line! p container line) container)

                  blank container

                  (accepts-lines? kind)
                  (let [line (if (and (= kind :heading) (not (nd/setext container)))
                               (chop-trailing-hashtags line)
                               line)]
                    (advance! p line (- (long (p-first-nonspace p)) (long (p-offset p))) false)
                    (add-line! p container line)
                    container)

                  :else
                  (let [para (add-child! p container :paragraph)]
                    (advance! p line (- (long (p-first-nonspace p)) (long (p-offset p))) false)
                    (add-line! p para line)
                    para))]
            (p-tip! p container)))))))

;; ---------------------------------------------------------------------------
;; Driver

(defn- process-line! [p ^String line]
  (p-offset! p 0)
  (p-column! p 0)
  (p-ptab! p false)
  (p-first-nonspace! p 0)
  (p-fn-column! p 0)
  (p-indent! p 0)
  (p-blank! p false)
  (p-line-no! p (inc (long (p-line-no p))))
  (when-let [last-matched (check-open-blocks p line)]
    (let [container (open-new-blocks p line last-matched)]
      (add-text-to-container p line container last-matched))))

(defn parse
  "Parses `input` into a block tree: a `:document` node whose paragraphs and
  headings carry their raw text (a StringBuilder in `text`)."
  [^String input]
  (let [root (doto (nd/make :document) (nd/open! true))
        p (->Parser root root 0 false 0 0 false 0 0 0 false)
        n (.length input)]
    (loop [start 0]
      (when (< start n)
        (let [nl (.indexOf input (int \newline) (int start))
              end (if (neg? nl) n nl)]
          (process-line! p (.substring input (int start) (int end)))
          (recur (inc end)))))
    (loop []
      (when-not (identical? (p-tip p) root)
        (p-tip! p (finalize! p (p-tip p)))
        (recur)))
    (finalize! p root)
    root))
