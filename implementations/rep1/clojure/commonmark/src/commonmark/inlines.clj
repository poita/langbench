(ns commonmark.inlines
  "Phase 2 of the conversion: parsing the raw text of a paragraph or heading
  into inline events.

  The parser follows the algorithm of Appendix A of the CommonMark
  specification (as implemented by cmark): a left-to-right scan that keeps a
  *delimiter stack* for runs of `*` and `_`, a *bracket stack* for `[` and
  `![`, and runs *process emphasis* when a link or image is completed and at
  the end of the text.

  The result is a flat vector of events rather than a tree, so arbitrarily deep
  nesting costs no stack. Events are vectors:

  | event                                | meaning                          |
  |--------------------------------------|----------------------------------|
  | `[:text s]`                          | literal text                     |
  | `[:code s]`                          | a code span                      |
  | `[:softbreak]` / `[:linebreak]`      | soft / hard line break           |
  | `[:start :emph]` / `[:end :emph]`    | emphasis                         |
  | `[:start :strong]` / `[:end :strong]`| strong emphasis                  |
  | `[:start :link m]` / `[:end :link]`  | link; `m` is `{:destination :title}` |
  | `[:start :image m]` / `[:end :image]`| image, same `m`                  |

  `:title` is nil when a link has no title. Start and end events nest properly."
  (:require [commonmark.scan :as scan]
            [commonmark.text :as t :refer [ch char-at]])
  (:import (java.util ArrayList)))

(set! *warn-on-reflection* true)

(def ^:private ^:const flag-open 1)
(def ^:private ^:const flag-close 2)

(def ^:private special-chars
  "Characters that end a run of plain text."
  (let [a (boolean-array 128)]
    (doseq [c "\n`\\&<*_[]!"] (aset a (int c) true))
    a))

(defn- code-span-content
  "Normalise the raw text between two backtick runs."
  ^String [^String raw]
  (let [s (.replace raw \newline \space)
        n (.length s)]
    (if (and (>= n 2)
             (== (char-at s 0) 32)
             (== (char-at s (dec n)) 32)
             (not (every? #(== (long (int %)) 32) s)))
      (.substring s 1 (dec n))
      s)))

(defn- brackets-push!
  [^ArrayList brackets image? tok pos]
  (.add brackets [image? tok pos]))

(defn parse-inlines
  "Parse the raw `content` of a paragraph or heading into a vector of inline
  events (see the namespace docstring)."
  [^String content]
  (let [s (t/rtrim-ws content)
        n (.length s)
        toks (ArrayList.)
        ;; --- delimiter stack: parallel arrays indexed by delimiter id ---
        cap (inc n)
        ^longs d-char (long-array cap)
        ^longs d-orig (long-array cap)
        ^longs d-flags (long-array cap)
        ^longs d-pos (long-array cap)
        ^longs d-rem (long-array cap)
        ^longs d-prev (long-array cap)
        ^longs d-next (long-array cap)
        ^objects d-opens (object-array cap)
        ^objects d-closes (object-array cap)
        ;; st: 0 = top delimiter (-1 if none), 1 = delimiter count,
        ;;     2 = link_closed flag, 3 = backtick "scanned" flag
        ^longs st (doto (long-array 4) (aset 0 -1) (aset 2 1))
        brackets (ArrayList.)
        ^longs ticks (when (>= (.indexOf s "`") 0) (long-array (+ n 2)))]
    (letfn [(add! [x] (.add toks x))
            (text! [^String x] (when-not (zero? (.length x)) (add! [:text x])))

            ;; ---- delimiter stack ------------------------------------------
            (push-delim! [c len flags pos]
              (let [id (aget st 1)
                    top (aget st 0)]
                (aset d-char id (long c))
                (aset d-orig id (long len))
                (aset d-rem id (long len))
                (aset d-flags id (long flags))
                (aset d-pos id (long pos))
                (aset d-prev id top)
                (aset d-next id -1)
                (when (>= top 0) (aset d-next top id))
                (aset st 0 id)
                (aset st 1 (inc id))
                (add! (Long/valueOf id))))

            (unlink! [^long x]
              (let [p (aget d-prev x)
                    nx (aget d-next x)]
                (when (>= p 0) (aset d-next p nx))
                (if (>= nx 0) (aset d-prev nx p) (aset st 0 p))))

            (can-open? [^long x] (pos? (bit-and (aget d-flags x) flag-open)))
            (can-close? [^long x] (pos? (bit-and (aget d-flags x) flag-close)))

            (kind [^long x]
              (+ (if (== (aget d-char x) (ch \_)) 6 0)
                 (if (can-open? x) 3 0)
                 (rem (aget d-orig x) 3)))

            (find-opener [^long closer ^long bottom]
              (let [cc (aget d-char closer)
                    clen (aget d-orig closer)
                    c-open? (can-open? closer)]
                (loop [x (aget d-prev closer)]
                  (when (and (>= x 0) (>= (aget d-pos x) bottom))
                    (if (and (can-open? x)
                             (== (aget d-char x) cc)
                             (or (not (or c-open? (can-close? x)))
                                 (zero? (rem clen 3))
                                 (not (zero? (rem (+ (aget d-orig x) clen) 3)))))
                      x
                      (recur (aget d-prev x)))))))

            (process-emphasis! [^long bottom]
              (let [first-entry (long (loop [x (aget st 0) f -1]
                                        (if (and (>= x 0) (>= (aget d-pos x) bottom))
                                          (recur (aget d-prev x) x)
                                          f)))]
                (when (>= first-entry 0)
                  (let [before (aget d-prev first-entry)
                        ^longs bottoms (long-array 12 bottom)]
                    (loop [closer first-entry]
                      (when (>= closer 0)
                        (if (can-close? closer)
                          (let [k (kind closer)
                                opener (find-opener closer (aget bottoms k))]
                            (if opener
                              (let [opener (long opener)
                                    use (if (and (>= (aget d-rem opener) 2) (>= (aget d-rem closer) 2)) 2 1)]
                                (aset d-rem opener (- (aget d-rem opener) use))
                                (aset d-rem closer (- (aget d-rem closer) use))
                                (aset d-next opener closer)
                                (aset d-prev closer opener)
                                (aset d-opens opener (cons use (aget d-opens opener)))
                                (aset d-closes closer (conj (or (aget d-closes closer) []) use))
                                (when (zero? (aget d-rem opener)) (unlink! opener))
                                (if (zero? (aget d-rem closer))
                                  (let [nx (aget d-next closer)]
                                    (unlink! closer)
                                    (recur nx))
                                  (recur closer)))
                              (let [nx (aget d-next closer)]
                                (aset bottoms k (aget d-pos closer))
                                (when-not (can-open? closer) (unlink! closer))
                                (recur nx))))
                          (recur (aget d-next closer)))))
                    ;; drop every entry at or after `bottom`
                    (aset st 0 before)
                    (when (>= before 0) (aset d-next before -1))))))

            ;; ---- code spans -------------------------------------------------
            (find-closing-ticks [^long p ^long len]
              (if (and (== (aget st 3) 1) (<= (aget ticks len) p))
                -1
                (loop [q p]
                  (let [b (.indexOf s "`" (int q))]
                    (if (neg? b)
                      (do (aset st 3 1) -1)
                      (let [e (long (loop [e b] (if (== (char-at s e) (ch \`)) (recur (inc e)) e)))
                            k (- e b)]
                        (aset ticks k b)
                        (if (== k len) b (recur e))))))))

            ;; ---- the individual constructs ---------------------------------
            (handle-delimiter [^long i ^long c]
              (let [j (loop [j i] (if (== (char-at s j) c) (recur (inc j)) j))
                    len (- j i)
                    before (if (zero? i) 10 (char-at s (dec i)))
                    after (if (== j n) 10 (char-at s j))
                    ws-before (t/ws? before) ws-after (t/ws? after)
                    p-before (t/ascii-punct? before) p-after (t/ascii-punct? after)
                    left? (and (not ws-after) (or (not p-after) ws-before p-before))
                    right? (and (not ws-before) (or (not p-before) ws-after p-after))
                    can-open (if (== c (ch \_)) (and left? (or (not right?) p-before)) left?)
                    can-close (if (== c (ch \_)) (and right? (or (not left?) p-after)) right?)]
                (if (or can-open can-close)
                  (push-delim! c len (+ (if can-open flag-open 0) (if can-close flag-close 0)) j)
                  (text! (.substring s (int i) (int j))))
                j))

            (handle-close-bracket [^long i]
              (if (.isEmpty brackets)
                (do (text! "]") (inc i))
                (let [[image? tok pos] (.get brackets (dec (.size brackets)))
                      pop! #(.remove brackets (dec (.size brackets)))]
                  (if (and (not image?) (== (aget st 2) 1))
                    (do (pop!) (text! "]") (inc i))
                    (if-let [[dest title end] (scan/scan-inline-link-tail s (inc i))]
                      (let [what (if image? :image :link)]
                        (.set toks (int tok) [:start what {:destination dest :title title}])
                        (add! [:end what])
                        (process-emphasis! pos)
                        (pop!)
                        (when-not image? (aset st 2 1))
                        end)
                      (do (pop!) (text! "]") (inc i)))))))

            (handle-backtick [^long i]
              (let [j (loop [j i] (if (== (char-at s j) (ch \`)) (recur (inc j)) j))
                    len (- j i)
                    close (long (find-closing-ticks j len))]
                (if (neg? close)
                  (do (text! (.substring s (int i) (int j))) j)
                  (do (add! [:code (code-span-content (.substring s (int j) (int close)))])
                      (+ close len)))))

            (handle-autolink [^long i]
              (if-let [[end email?] (scan/scan-autolink s i)]
                (let [end (long end)
                      body (t/decode-entities (.substring s (int (inc i)) (int (dec end))))
                      dest (if email? (str "mailto:" body) body)]
                  (add! [:start :link {:destination dest :title nil}])
                  (text! body)
                  (add! [:end :link])
                  end)
                (do (text! "<") (inc i))))

            (handle-newline [^long i]
              (add! (if (and (== (char-at s (- i 1)) 32) (== (char-at s (- i 2)) 32))
                      [:linebreak]
                      [:softbreak]))
              (loop [j (inc i)]
                (if (t/space-or-tab? (char-at s j)) (recur (inc j)) j)))

            (handle-backslash [^long i]
              (let [nx (char-at s (inc i))]
                (cond
                  (t/ascii-punct? nx) (do (text! (String/valueOf (char nx))) (+ i 2))
                  (== nx 10) (do (add! [:linebreak]) (+ i 2))
                  :else (do (text! "\\") (inc i)))))

            (handle-plain [^long i]
              (let [e (loop [j (inc i)]
                        (let [c (char-at s j)]
                          (if (or (neg? c)
                                  (and (< c 128) (aget ^booleans special-chars (int c))))
                            j
                            (recur (inc j)))))
                    run (.substring s (int i) (int e))]
                (text! (if (== (char-at s e) 10) (t/rtrim-ws run) run))
                e))]
      (loop [i 0]
        (when (< i n)
          (let [c (char-at s i)]
            (recur
             (long
              (cond
                (== c 10) (handle-newline i)
                (== c (ch \`)) (handle-backtick i)
                (== c (ch \\)) (handle-backslash i)
                (== c (ch \&)) (if-let [[end rep] (t/match-entity s i)]
                                 (do (text! rep) end)
                                 (do (text! "&") (inc i)))
                (== c (ch \<)) (handle-autolink i)
                (or (== c (ch \*)) (== c (ch \_))) (handle-delimiter i c)
                (== c (ch \[)) (do (brackets-push! brackets false (.size toks) (inc i))
                                   (add! [:text "["])
                                   (aset st 2 0)
                                   (inc i))
                (== c (ch \!)) (if (== (char-at s (inc i)) (ch \[))
                                 (do (brackets-push! brackets true (.size toks) (+ i 2))
                                     (add! [:text "!["])
                                     (+ i 2))
                                 (do (text! "!") (inc i)))
                (== c (ch \])) (handle-close-bracket i)
                :else (handle-plain i)))))))
      (process-emphasis! 0)
      ;; assemble the final event vector
      (let [out (transient [])
            size (.size toks)]
        (loop [k 0 out out]
          (if (< k size)
            (let [x (.get toks k)]
              (if (instance? Long x)
                (let [id (long x)
                      rem (aget d-rem id)
                      out (reduce (fn [o u] (conj! o [:end (if (== (long u) 2) :strong :emph)]))
                                  out (aget d-closes id))
                      out (if (pos? rem)
                            (conj! out [:text (.repeat (String/valueOf (char (aget d-char id))) (int rem))])
                            out)
                      out (reduce (fn [o u] (conj! o [:start (if (== (long u) 2) :strong :emph)]))
                                  out (aget d-opens id))]
                  (recur (inc k) out))
                (recur (inc k) (conj! out x))))
            (persistent! out)))))))
