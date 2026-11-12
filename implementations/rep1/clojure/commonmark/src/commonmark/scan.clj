(ns commonmark.scan
  "Scanners for the inline constructs that need more than a character class:
  autolinks, link destinations and link titles.

  Every scanner starts at a given index of the string and examines only the
  characters it consumes (plus a bounded amount of look-ahead), so using them
  repeatedly never rescans the rest of the content."
  (:require [commonmark.text :as t :refer [ch char-at]]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Autolinks
;; ---------------------------------------------------------------------------

(defn- scan-uri-autolink
  "`<scheme:rest>` with `i` just after the `<`. Returns the index just after
  the closing `>` or -1."
  ^long [^String s ^long i]
  (if (t/alpha? (char-at s i))
    ;; scheme: a letter followed by 1-31 letters, digits, `+`, `.` or `-`
    (let [scheme-end (loop [j (inc i)]
                       (let [c (char-at s j)]
                         (if (and (< (- j i) 32)
                                  (or (t/alnum? c) (== c (ch \+)) (== c (ch \-)) (== c (ch \.))))
                           (recur (inc j))
                           j)))]
      (if (and (>= (- scheme-end i) 2) (== (char-at s scheme-end) (ch \:)))
        (loop [j (inc scheme-end)]
          (let [c (char-at s j)]
            (cond (== c (ch \>)) (inc j)
                  (or (<= c 32) (== c (ch \<))) -1
                  :else (recur (inc j)))))
        -1))
    -1))

(defn- email-local-char? [^long c]
  (or (t/alnum? c)
      (>= (.indexOf ".!#$%&'*+/=?^_`{|}~-" (int c)) 0)))

(defn- scan-email-autolink
  "`<local@domain>` with `i` just after the `<`. Returns the index just after
  the closing `>` or -1."
  ^long [^String s ^long i]
  (let [at (loop [j i] (if (email-local-char? (char-at s j)) (recur (inc j)) j))]
    (if (and (> at i) (== (char-at s at) (ch \@)))
      ;; domain: label ("." label)* ">" where a label is 1-63 alphanumerics or
      ;; hyphens that starts and ends with an alphanumeric.
      (loop [j (inc at)]
        (let [label-end (loop [k j]
                          (let [c (char-at s k)]
                            (if (or (t/alnum? c) (== c (ch \-))) (recur (inc k)) k)))
              len (- label-end j)]
          (if (and (pos? len)
                   (<= len 63)
                   (t/alnum? (char-at s j))
                   (t/alnum? (char-at s (dec label-end))))
            (let [c (char-at s label-end)]
              (cond (== c (ch \>)) (inc label-end)
                    (== c (ch \.)) (recur (inc label-end))
                    :else -1))
            -1)))
      -1)))

(defn scan-autolink
  "If an autolink starts at index `i` (where `s[i]` is `<`), return
  `[end email?]` where `end` is the index just after the closing `>`;
  otherwise nil."
  [^String s ^long i]
  (let [start (inc i)
        uri (scan-uri-autolink s start)]
    (if (>= uri 0)
      [uri false]
      (let [email (scan-email-autolink s start)]
        (when (>= email 0)
          [email true])))))

;; ---------------------------------------------------------------------------
;; Link destinations and titles
;; ---------------------------------------------------------------------------

(defn skip-ws
  "Index of the first non-whitespace character of `s` at or after `i`."
  ^long [^String s ^long i]
  (loop [j i]
    (if (t/ws? (char-at s j)) (recur (inc j)) j)))

(defn- scan-bracketed-destination
  "`<...>` destination starting at `i`. Returns [content-start content-end next]
  or nil."
  [^String s ^long i]
  (let [n (.length s)]
    (loop [j (inc i)]
      (when (< j n)
        (let [c (char-at s j)]
          (cond
            (== c (ch \>)) (when (< (inc j) n) [(inc i) j (inc j)])
            (== c (ch \\)) (recur (+ j 2))
            (or (== c (ch \newline)) (== c (ch \<))) nil
            :else (recur (inc j))))))))

(defn- scan-bare-destination
  "Destination without angle brackets starting at `i`. Returns [start end next]
  or nil."
  [^String s ^long i]
  (let [n (.length s)]
    (loop [j i depth 0]
      (when (< j n)
        (let [c (char-at s j)]
          (cond
            (and (== c (ch \\)) (t/ascii-punct? (char-at s (inc j))))
            (recur (+ j 2) depth)

            (== c (ch \())
            (when (< depth 32) (recur (inc j) (inc depth)))

            (== c (ch \)))
            (if (zero? depth)
              [i j j]
              (recur (inc j) (dec depth)))

            (t/ws? c)
            (when (zero? depth) [i j j])

            :else (recur (inc j) depth)))))))

(defn scan-link-destination
  "Scan a link destination at `i`. Returns `[start end next]` (the raw
  destination is `s[start, end)` and scanning continues at `next`) or nil."
  [^String s ^long i]
  (if (== (char-at s i) (ch \<))
    (scan-bracketed-destination s i)
    (scan-bare-destination s i)))

(defn scan-link-title
  "Scan a link title starting at `i`. Returns the index just after the title,
  or -1 when no title starts there. A title is delimited by `\"`, `'` or
  parentheses; the closing delimiter may occur inside only when escaped. The
  longest possible match is returned."
  ^long [^String s ^long i]
  (let [n (.length s)
        open (char-at s i)
        close (cond (or (== open (ch \")) (== open (ch \'))) open
                    (== open (ch \()) (ch \))
                    :else -1)]
    (if (neg? close)
      -1
      (let [paren? (== open (ch \())]
        ;; Positions reachable "inside the title" are tracked in a sliding
        ;; window: `a`, `b` and `c` say whether position j, j+1 and j+2 can be
        ;; reached. A backslash before punctuation may be an escape pair
        ;; (jump to j+2) or a plain character (go to j+1); that ambiguity is
        ;; what makes a trailing backslash-quote possibly close the title.
        (loop [j (inc i) a true b false c false best -1]
          (if (or (>= j n) (not (or a b c)))
            best
            (let [x (char-at s j)
                  stop? (or (== x close) (and paren? (== x (ch \())))
                  esc? (and a (== x (ch \\)) (t/ascii-punct? (char-at s (inc j))))
                  best (if (and a (== x close)) (inc j) best)]
              (recur (inc j) (boolean (or b (and a (not stop?)))) (boolean (or c esc?)) false best))))))))

(defn scan-inline-link-tail
  "Parse `(destination \"title\")` starting at the `(` at index `i`. On success
  returns `[destination title end]` where destination and title are decoded
  strings (title is nil when absent) and `end` is the index just after the
  `)`. Returns nil when the text is not a valid inline link tail."
  [^String s ^long i]
  (when (== (char-at s i) (ch \())
    (let [p (skip-ws s (inc i))]
      (when-let [[ds de dnext] (scan-link-destination s p)]
        (let [ds (long ds) de (long de) dnext (long dnext)
              q (skip-ws s dnext)
              title-end (if (== q dnext) -1 (scan-link-title s q))
              title (when (pos? title-end)
                      (t/clean-string (.substring s (int (inc q)) (int (dec title-end)))))
              r (if (pos? title-end) (skip-ws s title-end) q)]
          (when (== (char-at s r) (ch \)))
            [(t/clean-string (t/trim-ws (.substring s (int ds) (int de))))
             title
             (inc r)]))))))
