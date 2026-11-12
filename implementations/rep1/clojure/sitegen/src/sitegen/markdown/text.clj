(ns sitegen.markdown.text
  "Character classes and small text transformations shared by the Markdown
  block parser, inline parser and HTML renderer: whitespace and punctuation
  predicates, entity decoding, backslash-escape removal, HTML escaping and URL
  encoding."
  (:import (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

(defn ws?
  "True for the ASCII whitespace set of cmark: space, TAB, LF, VT, FF, CR."
  [c]
  (let [c (int c)]
    (or (== c 32) (== c 9) (== c 10) (== c 11) (== c 12) (== c 13))))

(defn space-or-tab? [c]
  (let [c (int c)] (or (== c 32) (== c 9))))

(defn ascii-punct?
  "True for the ASCII punctuation characters !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~."
  [c]
  (let [c (int c)]
    (or (<= 33 c 47) (<= 58 c 64) (<= 91 c 96) (<= 123 c 126))))

(defn ascii-alpha? [c]
  (let [c (int c)] (or (<= 65 c 90) (<= 97 c 122))))

(defn ascii-digit? [c]
  (let [c (int c)] (<= 48 c 57)) )

(defn ascii-alnum? [c]
  (or (ascii-alpha? c) (ascii-digit? c)))

(defn rtrim
  "Removes trailing whitespace (the cmark whitespace set) from `s`."
  ^String [^String s]
  (loop [n (.length s)]
    (if (and (pos? n) (ws? (.charAt s (dec n))))
      (recur (dec n))
      (if (== n (.length s)) s (.substring s 0 n)))))

(defn trim
  "Removes leading and trailing whitespace (the cmark whitespace set)."
  ^String [^String s]
  (let [e (.length (rtrim s))]
    (loop [b 0]
      (if (and (< b e) (ws? (.charAt s b)))
        (recur (inc b))
        (.substring s b e)))))

;; ---------------------------------------------------------------------------
;; Entities and escapes

(defn- hex-digit? [c]
  (let [c (int c)] (or (<= 48 c 57) (<= 65 c 70) (<= 97 c 102))))

(defn- scan-digits
  "Index after the run of at most `max` digits (decimal or hex) starting at
  `i`, or -1 when there are fewer than one."
  ^long [^String s ^long i hex? ^long limit]
  (let [n (.length s)]
    (loop [j i]
      (if (and (< j n) (< (- j i) limit)
               (if hex? (hex-digit? (.charAt s j)) (ascii-digit? (.charAt s j))))
        (recur (inc j))
        (if (== j i) -1 j)))))

(defn append-entity!
  "If an entity reference starts at index `i` of `s` (where `s[i]` is `&`),
  appends the character it denotes to `sb` and returns the index just after
  the `;`.  Returns -1 (appending nothing) when no reference starts there.

  Recognised: `&#` 1-7 decimal digits `;`, `&#x`/`&#X` 1-6 hex digits `;`, and
  the four named references `&amp; &lt; &gt; &quot;`."
  ^long [^StringBuilder sb ^String s ^long i]
  (let [n (.length s)
        j (inc i)]
    (cond
      (>= j n) -1

      (== (int (.charAt s j)) (int \#))
      (let [k (inc j)]
        (if (and (< k n) (let [c (.charAt s k)] (or (== (int c) (int \x)) (== (int c) (int \X)))))
          (let [e (scan-digits s (inc k) true 6)]
            (if (and (pos? e) (< e n) (== (int (.charAt s e)) (int \;)))
              (let [cp (Long/parseLong (.substring s (inc k) e) 16)]
                (.appendCodePoint sb (int (if (or (zero? cp) (<= 0xD800 cp 0xDFFF) (> cp 0x10FFFF)) 0xFFFD cp)))
                (inc e))
              -1))
          (let [e (scan-digits s k false 7)]
            (if (and (pos? e) (< e n) (== (int (.charAt s e)) (int \;)))
              (let [cp (Long/parseLong (.substring s k e))]
                (.appendCodePoint sb (int (if (or (zero? cp) (<= 0xD800 cp 0xDFFF) (> cp 0x10FFFF)) 0xFFFD cp)))
                (inc e))
              -1))))

      (.startsWith s "amp;" (int j)) (do (.append sb \&) (+ j 4))
      (.startsWith s "lt;" (int j))  (do (.append sb \<) (+ j 3))
      (.startsWith s "gt;" (int j))  (do (.append sb \>) (+ j 3))
      (.startsWith s "quot;" (int j)) (do (.append sb \") (+ j 5))
      :else -1)))

(defn decode-entities
  "Replaces every entity reference in `s` (see `append-entity!`) by the
  character it denotes."
  ^String [^String s]
  (if (neg? (.indexOf s (int \&)))
    s
    (let [n (.length s)
          sb (StringBuilder. n)]
      (loop [i 0]
        (when (< i n)
          (let [c (.charAt s i)]
            (if (== (int c) (int \&))
              (let [e (append-entity! sb s i)]
                (if (neg? e)
                  (do (.append sb c) (recur (inc i)))
                  (recur e)))
              (do (.append sb c) (recur (inc i)))))))
      (.toString sb))))

(defn unescape-backslashes
  "Removes the backslash of every backslash-escaped ASCII punctuation
  character in `s`."
  ^String [^String s]
  (if (neg? (.indexOf s (int \\)))
    s
    (let [n (.length s)
          sb (StringBuilder. n)]
      (loop [i 0]
        (when (< i n)
          (let [c (.charAt s i)]
            (if (and (== (int c) (int \\)) (< (inc i) n) (ascii-punct? (.charAt s (inc i))))
              (do (.append sb (.charAt s (inc i))) (recur (+ i 2)))
              (do (.append sb c) (recur (inc i)))))))
      (.toString sb))))

(defn clean-text
  "Entity decoding followed by backslash-escape removal, as applied to link
  destinations, titles and fenced-code info strings."
  ^String [^String s]
  (unescape-backslashes (decode-entities s)))

;; ---------------------------------------------------------------------------
;; Output encoding

(defn escape-html
  "Replaces `&`, `<`, `>` and `\"` by their entity references."
  ^String [^String s]
  (let [n (.length s)]
    (loop [i 0]
      (if (< i n)
        (let [c (.charAt s i)]
          (if (or (== (int c) (int \&)) (== (int c) (int \<)) (== (int c) (int \>)) (== (int c) (int \")))
            (let [sb (StringBuilder. (+ n 16))]
              (.append sb s 0 i)
              (loop [j i]
                (when (< j n)
                  (let [c (.charAt s j)]
                    (case c
                      \& (.append sb "&amp;")
                      \< (.append sb "&lt;")
                      \> (.append sb "&gt;")
                      \" (.append sb "&quot;")
                      (.append sb c))
                    (recur (inc j)))))
              (.toString sb))
            (recur (inc i))))
        s))))

(defn append-escaped!
  "Appends `s` HTML-escaped to the StringBuilder `sb`."
  [^StringBuilder sb ^String s]
  (.append sb (escape-html s)))

(def ^:private hex-chars "0123456789ABCDEF")

(defn- url-safe? [b]
  (let [b (int b)]
    (or (<= 65 b 90) (<= 97 b 122) (<= 48 b 57)
        (case (char b)
          (\- \_ \. \~ \! \# \$ \% \( \) \* \+ \, \/ \: \; \= \? \@) true
          false))))

(defn- starts-with-ci? [^String s ^String prefix]
  (.regionMatches s true 0 prefix 0 (.length prefix)))

(defn href
  "The value of an `href`/`src` attribute for the link destination `dest`:
  empty for unsafe schemes, otherwise the UTF-8 bytes of `dest` percent-encoded
  and HTML-escaped as cmark does."
  ^String [^String dest]
  (if (and (or (starts-with-ci? dest "javascript:") (starts-with-ci? dest "vbscript:")
               (starts-with-ci? dest "file:") (starts-with-ci? dest "data:"))
           (not (or (starts-with-ci? dest "data:image/png") (starts-with-ci? dest "data:image/gif")
                    (starts-with-ci? dest "data:image/jpeg") (starts-with-ci? dest "data:image/webp"))))
    ""
    (let [bs (.getBytes dest StandardCharsets/UTF_8)
          sb (StringBuilder. (alength bs))]
      (dotimes [i (alength bs)]
        (let [b (bit-and (long (aget bs i)) 0xFF)]
          (cond
            (url-safe? b) (.append sb (char b))
            (== b (int \&)) (.append sb "&amp;")
            (== b (int \')) (.append sb "&#x27;")
            :else (doto sb
                    (.append \%)
                    (.append (.charAt ^String hex-chars (bit-shift-right b 4)))
                    (.append (.charAt ^String hex-chars (bit-and b 15)))))))
      (.toString sb))))
