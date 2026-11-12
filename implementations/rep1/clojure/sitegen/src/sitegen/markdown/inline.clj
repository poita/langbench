(ns sitegen.markdown.inline
  "Phase 2 of the Markdown conversion: parses the raw text of paragraphs and
  headings into inline nodes with cmark's algorithm - a left-to-right scan
  that keeps a delimiter stack for `*`/`_` runs and a bracket stack for links
  and images, then resolves emphasis with the `openers_bottom` optimisation."
  (:require [sitegen.markdown.node :as nd]
            [sitegen.markdown.text :as t]
            [sitegen.mutable :refer [defmutable]]))

(set! *warn-on-reflection* true)

;; A delimiter-stack entry for a run of `*` or `_`.  `len` is the original
;; run length, `node` the text node holding the run, `position` the index
;; just after the run.
(defmutable Delim "d-" [ch len can-open can-close node position prev next])

;; A bracket-stack entry for `[` or `![`.
(defmutable Bracket "b-" [image node position])

;; The state of one inline parse.
(defmutable Subject "s-"
  [input pos root delim-top brackets link-closed bt-last bt-scanned])

(defn- code-at
  "The character code at `i` of `s`, or -1 outside the string."
  ^long [^String s ^long i]
  (if (and (>= i 0) (< i (.length s))) (long (int (.charAt s i))) -1))

(defn- add-node! [subj kind]
  (nd/append-child! (s-root subj) (nd/make kind)))

(defn- add-text! [subj ^String text]
  (nd/append-child! (s-root subj) (nd/make-text :text text)))

;; ---------------------------------------------------------------------------
;; Code spans

(defn- find-closing-backticks
  "Searches for a run of exactly `n` backticks starting at or after `p`, using
  cmark's memo of the last position seen for each run length.  Returns the
  start of the run or -1."
  ^long [subj ^long n ^long p]
  (let [^String s (s-input subj)
        ^longs memo (s-bt-last subj)]
    (if (and (s-bt-scanned subj) (<= (aget memo n) p))
      -1
      (let [len (.length s)]
        (loop [i p]
          (let [j (long (.indexOf s (int \`) (int i)))]
            (if (neg? j)
              (do (s-bt-scanned! subj true) -1)
              (let [k (long (loop [e j] (if (and (< e len) (= (.charAt s e) \`)) (recur (inc e)) (- e j))))]
                (when (< k (alength memo)) (aset memo k j))
                (if (== k n)
                  j
                  (recur (+ j k)))))))))))

(defn- handle-backticks! [subj]
  (let [^String s (s-input subj)
        pos (long (s-pos subj))
        len (.length s)
        n (loop [e pos] (if (and (< e len) (= (.charAt s e) \`)) (recur (inc e)) (- e pos)))
        p (+ pos n)
        close (find-closing-backticks subj n p)]
    (if (neg? close)
      (do (add-text! subj (.substring s (int pos) (int p)))
          (s-pos! subj p))
      (let [raw (.replace (.substring s (int p) (int close)) \newline \space)
            rl (.length raw)
            strip? (and (>= rl 2)
                        (= (.charAt raw 0) \space)
                        (= (.charAt raw (dec rl)) \space)
                        (not (every? #(== (int %) 32) raw)))
            content (if strip? (.substring raw 1 (dec rl)) raw)]
        (nd/append-child! (s-root subj) (nd/make-text :code content))
        (s-pos! subj (+ close n))))))

;; ---------------------------------------------------------------------------
;; Autolinks

(defn- scheme? [^String s ^long k]
  (and (<= 2 k 32)
       (t/ascii-alpha? (.charAt s 0))
       (loop [i 1]
         (or (>= i k)
             (let [c (.charAt s i)]
               (and (or (t/ascii-alnum? c) (== (int c) (int \.)) (== (int c) (int \+)) (== (int c) (int \-)))
                    (recur (inc i))))))))

(defn- email-local-char? [c]
  (or (t/ascii-alnum? c)
      (<= 0 (.indexOf ".!#$%&'*+/=?^_`{|}~-" (int c)))))

(defn- email? [^String s]
  (let [at (.indexOf s (int \@))]
    (and (pos? at)
         (every? email-local-char? (.substring s 0 at))
         (let [domain (.substring s (inc at))]
           (and (pos? (.length domain))
                (every? (fn [^String label]
                          (let [l (.length label)]
                            (and (<= 1 l 63)
                                 (t/ascii-alnum? (.charAt label 0))
                                 (t/ascii-alnum? (.charAt label (dec l)))
                                 (every? #(or (t/ascii-alnum? %) (== (int %) (int \-))) label))))
                        (.split domain "\\." -1)))))))

(defn- handle-lt! [subj]
  (let [^String s (s-input subj)
        pos (long (s-pos subj))
        len (.length s)
        e (loop [j (inc pos)]
            (if (and (< j len)
                     (let [c (.charAt s j)] (and (> (int c) 32) (not= c \<) (not= c \>))))
              (recur (inc j))
              j))]
    (if (and (< e len) (= (.charAt s e) \>))
      (let [text (.substring s (int (inc pos)) (int e))
            colon (.indexOf text (int \:))
            uri? (and (pos? colon) (scheme? text colon))
            mail? (and (not uri?) (email? text))]
        (if (or uri? mail?)
          (let [decoded (t/decode-entities text)
                link (nd/make :link)]
            (nd/dest! link (if mail? (str "mailto:" decoded) decoded))
            (nd/append-child! link (nd/make-text :text decoded))
            (nd/append-child! (s-root subj) link)
            (s-pos! subj (inc e)))
          (do (add-text! subj "<") (s-pos! subj (inc pos)))))
      (do (add-text! subj "<") (s-pos! subj (inc pos))))))

;; ---------------------------------------------------------------------------
;; Delimiter runs and emphasis

(defn- punct? [c] (and (>= (long c) 0) (t/ascii-punct? c)))
(defn- space? [c] (and (>= (long c) 0) (t/ws? c)))

(defn- handle-delim-run! [subj]
  (let [^String s (s-input subj)
        pos (long (s-pos subj))
        len (.length s)
        c (.charAt s pos)
        e (loop [j pos] (if (and (< j len) (= (.charAt s j) c)) (recur (inc j)) j))
        before (if (zero? pos) 10 (code-at s (dec pos)))
        after (if (>= e len) 10 (code-at s e))
        left? (and (not (space? after))
                   (or (not (punct? after)) (space? before) (punct? before)))
        right? (and (not (space? before))
                    (or (not (punct? before)) (space? after) (punct? after)))
        star? (== (int c) (int \*))
        can-open (if star? left? (and left? (or (not right?) (punct? before))))
        can-close (if star? right? (and right? (or (not left?) (punct? after))))
        node (add-text! subj (.substring s (int pos) (int e)))]
    (when (or can-open can-close)
      (let [top (s-delim-top subj)
            d (->Delim c (- e pos) can-open can-close node e top nil)]
        (when top (d-next! top d))
        (s-delim-top! subj d)))
    (s-pos! subj e)))

(defn- remove-delim! [subj d]
  (let [prev (d-prev d) nxt (d-next d)]
    (when prev (d-next! prev nxt))
    (if nxt
      (d-prev! nxt prev)
      (s-delim-top! subj prev))))

(defn- kind-index [d]
  (+ (if (== (int (d-ch d)) (int \_)) 6 0)
     (if (d-can-open d) 3 0)
     (rem (long (d-len d)) 3)))

(defn- process-emphasis!
  "Resolves emphasis among the delimiter entries whose position is at least
  `bottom`, then removes those entries."
  [subj ^long bottom]
  (let [top (s-delim-top subj)
        ^longs openers-bottom (long-array 12 bottom)
        first-entry (when (and top (>= (long (d-position top)) bottom))
                      (loop [d top]
                        (let [pv (d-prev d)]
                          (if (and pv (>= (long (d-position pv)) bottom)) (recur pv) d))))]
    (loop [closer first-entry]
      (when closer
        (if (d-can-close closer)
          (let [idx (kind-index closer)
                ob (aget openers-bottom idx)
                clen (long (d-len closer))
                opener (loop [o (d-prev closer)]
                         (cond
                           (or (nil? o) (< (long (d-position o)) ob)) nil
                           (and (d-can-open o)
                                (== (int (d-ch o)) (int (d-ch closer)))
                                (or (not (or (d-can-open closer) (d-can-close o)))
                                    (zero? (rem clen 3))
                                    (not (zero? (rem (+ (long (d-len o)) clen) 3)))))
                           o
                           :else (recur (d-prev o))))]
            (if opener
              (let [onode (d-node opener)
                    cnode (d-node closer)
                    ^String otext (nd/text onode)
                    ^String ctext (nd/text cnode)
                    use (if (and (>= (.length otext) 2) (>= (.length ctext) 2)) 2 1)
                    em (nd/make (if (== use 2) :strong :emph))]
                (nd/text! onode (.substring otext 0 (- (.length otext) use)))
                (nd/text! cnode (.substring ctext use))
                ;; drop the entries between opener and closer
                (d-next! opener closer)
                (d-prev! closer opener)
                ;; wrap the nodes between the two text nodes
                (nd/insert-after! onode em)
                (loop [n (nd/next-sibling em)]
                  (when-not (identical? n cnode)
                    (let [nxt (nd/next-sibling n)]
                      (nd/unlink! n)
                      (nd/append-child! em n)
                      (recur nxt))))
                (when (zero? (.length ^String (nd/text onode)))
                  (nd/unlink! onode)
                  (remove-delim! subj opener))
                (if (zero? (.length ^String (nd/text cnode)))
                  (let [nxt (d-next closer)]
                    (nd/unlink! cnode)
                    (remove-delim! subj closer)
                    (recur nxt))
                  (recur closer)))
              (let [nxt (d-next closer)]
                (aset openers-bottom idx (long (d-position closer)))
                (when-not (d-can-open closer) (remove-delim! subj closer))
                (recur nxt))))
          (recur (d-next closer)))))
    ;; remove every entry at or above the bottom
    (loop [d (s-delim-top subj)]
      (if (and d (>= (long (d-position d)) bottom))
        (recur (d-prev d))
        (do (when d (d-next! d nil))
            (s-delim-top! subj d))))))

;; ---------------------------------------------------------------------------
;; Links and images

(defn- skip-ws ^long [^String s ^long i]
  (loop [i i] (if (and (< i (.length s)) (t/ws? (.charAt s i))) (recur (inc i)) i)))

(defn- scan-destination
  "Scans a link destination starting at `i`.  Returns [raw-start raw-end next]
  or nil when it is invalid."
  [^String s ^long i]
  (let [len (.length s)]
    (if (and (< i len) (= (.charAt s i) \<))
      (loop [j (inc i)]
        (if (>= j len)
          nil
          (let [c (.charAt s j)]
            (cond
              (= c \>) (when (< (inc j) len) [(inc i) j (inc j)])
              (= c \\) (recur (+ j 2))
              (or (= c \newline) (= c \<)) nil
              :else (recur (inc j))))))
      (loop [j i depth 0]
        (if (>= j len)
          nil
          (let [c (.charAt s j)]
            (cond
              (and (= c \\) (< (inc j) len) (t/ascii-punct? (.charAt s (inc j)))) (recur (+ j 2) depth)
              (= c \() (when (< depth 32) (recur (inc j) (inc depth)))
              (= c \)) (if (zero? depth) [i j j] (recur (inc j) (dec depth)))
              (t/ws? c) (when (zero? depth) [i j j])
              :else (recur (inc j) depth))))))))

(defn- scan-title
  "Scans a title starting at `i`.  Returns [content-start content-end next] or
  nil when none starts there.  The longest match wins; the closing delimiter
  (and for parentheses also an opening one) may appear inside only when
  immediately preceded by a backslash."
  [^String s ^long i]
  (let [len (.length s)
        open (code-at s i)
        close (cond (== open (int \")) (int \") (== open (int \')) (int \') (== open (int \()) (int \)))]
    (when close
      (loop [j (inc i) best -1]
        (let [result (fn [] (when (>= best 0) [(inc i) best (inc best)]))]
          (if (>= j len)
            (result)
            (let [c (long (int (.charAt s j)))
                  escaped? (== (code-at s (dec j)) (int \\))]
              (cond
                (== c (long close)) (if escaped? (recur (inc j) j) [(inc i) j (inc j)])
                (and (== open (int \()) (== c (int \()) (not escaped?)) (result)
                :else (recur (inc j) best)))))))))

(defn- scan-inline-link
  "Tries to parse `(destination \"title\")` starting at `i`, the index just
  after a `]`.  Returns [dest title end] with `end` just after the `)`, or nil."
  [^String s ^long i]
  (when (== (code-at s i) (int \())
    (let [d0 (skip-ws s (inc i))]
      (when-let [[ds de dnext] (scan-destination s d0)]
        (let [dnext (long dnext)
              t0 (skip-ws s dnext)
              title (when (> t0 dnext) (scan-title s t0))
              t-end (if title (long (nth title 2)) t0)
              end (skip-ws s t-end)]
          (when (== (code-at s end) (int \)))
            [(t/clean-text (t/trim (.substring s (int ds) (int de))))
             (when title (t/clean-text (.substring s (int (nth title 0)) (int (nth title 1)))))
             (inc end)]))))))

(defn- handle-close-bracket! [subj]
  (let [^String s (s-input subj)
        pos (long (s-pos subj))
        ^java.util.ArrayList brackets (s-brackets subj)
        text-bracket! (fn [] (add-text! subj "]") (s-pos! subj (inc pos)))]
    (if (.isEmpty brackets)
      (text-bracket!)
      (let [opener (.get brackets (dec (.size brackets)))
            image? (b-image opener)]
        (if (and (not image?) (s-link-closed subj))
          (do (.remove brackets (dec (.size brackets)))
              (text-bracket!))
          (if-let [[dest title end] (scan-inline-link s (inc pos))]
            (let [node (nd/make (if image? :image :link))
                  onode (b-node opener)]
              (nd/dest! node dest)
              (nd/title! node title)
              (nd/insert-after! onode node)
              (loop [n (nd/next-sibling node)]
                (when n
                  (let [nxt (nd/next-sibling n)]
                    (nd/unlink! n)
                    (nd/append-child! node n)
                    (recur nxt))))
              (nd/unlink! onode)
              (process-emphasis! subj (long (b-position opener)))
              (.remove brackets (dec (.size brackets)))
              (when-not image? (s-link-closed! subj true))
              (s-pos! subj end))
            (do (.remove brackets (dec (.size brackets)))
                (text-bracket!))))))))

;; ---------------------------------------------------------------------------
;; The main loop

(defn- special? [c]
  (case c (\newline \` \\ \& \< \* \_ \[ \] \!) true false))

(defn- handle-newline! [subj]
  (let [^String s (s-input subj)
        pos (long (s-pos subj))
        hard? (and (>= pos 2) (= (.charAt s (- pos 1)) \space) (= (.charAt s (- pos 2)) \space))]
    (add-node! subj (if hard? :linebreak :softbreak))
    (s-pos! subj (loop [i (inc pos)]
                   (if (and (< i (.length s)) (t/space-or-tab? (.charAt s i))) (recur (inc i)) i)))))

(defn- handle-backslash! [subj]
  (let [^String s (s-input subj)
        pos (long (s-pos subj))
        nxt (code-at s (inc pos))]
    (cond
      (and (>= nxt 0) (t/ascii-punct? nxt))
      (do (add-text! subj (String/valueOf (char nxt))) (s-pos! subj (+ pos 2)))

      (== nxt 10)
      (do (add-node! subj :linebreak) (s-pos! subj (+ pos 2)))

      :else
      (do (add-text! subj "\\") (s-pos! subj (inc pos))))))

(defn- handle-entity! [subj]
  (let [^String s (s-input subj)
        pos (long (s-pos subj))
        sb (StringBuilder.)
        e (t/append-entity! sb s pos)]
    (if (neg? e)
      (do (add-text! subj "&") (s-pos! subj (inc pos)))
      (do (add-text! subj (.toString sb)) (s-pos! subj e)))))

(defn- handle-text! [subj]
  (let [^String s (s-input subj)
        pos (long (s-pos subj))
        len (.length s)
        e (loop [j pos] (if (and (< j len) (not (special? (.charAt s j)))) (recur (inc j)) j))
        run (.substring s (int pos) (int e))
        run (if (and (< e len) (= (.charAt s e) \newline)) (t/rtrim run) run)]
    (when (pos? (.length run)) (add-text! subj run))
    (s-pos! subj e)))

(defn parse-inlines!
  "Parses `content` (the text of a paragraph or heading, trailing whitespace
  already removed) and appends the resulting inline nodes to `root`."
  [root ^String content]
  (let [subj (->Subject content 0 root nil (java.util.ArrayList.) true (long-array 128) false)
        len (.length content)]
    (loop []
      (let [pos (long (s-pos subj))]
        (when (< pos len)
          (let [c (.charAt content pos)]
            (case c
              \newline (handle-newline! subj)
              \` (handle-backticks! subj)
              \\ (handle-backslash! subj)
              \& (handle-entity! subj)
              \< (handle-lt! subj)
              (\* \_) (handle-delim-run! subj)
              \[ (do (let [node (add-text! subj "[")]
                       (.add ^java.util.ArrayList (s-brackets subj) (->Bracket false node (inc pos))))
                     (s-link-closed! subj false)
                     (s-pos! subj (inc pos)))
              \! (if (== (code-at content (inc pos)) (int \[))
                   (let [node (add-text! subj "![")]
                     (.add ^java.util.ArrayList (s-brackets subj) (->Bracket true node (+ pos 2)))
                     (s-pos! subj (+ pos 2)))
                   (do (add-text! subj "!") (s-pos! subj (inc pos))))
              \] (handle-close-bracket! subj)
              (handle-text! subj))
            (recur)))))
    (process-emphasis! subj 0)
    root))

(defn parse-all!
  "Parses the inline content of every paragraph and heading below `root`."
  [root]
  (nd/walk! root
            (fn [node entering?]
              (when (and entering? (#{:paragraph :heading} (nd/kind node)))
                (parse-inlines! node (t/rtrim (.toString ^StringBuilder (nd/text node))))))))
