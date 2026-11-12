(ns commonmark.text
  "Low-level text helpers shared by the block parser, the inline parser and the
  HTML renderer: ASCII character classes, entity and backslash-escape
  decoding, HTML escaping and URL percent-encoding.

  Characters are handled as `long` UTF-16 code units; `-1` stands for \"past
  the end of the string\". Use the [[ch]] macro for character literals."
  (:import (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

(defmacro ch
  "Expands a character literal into its code unit as a `long`, so that it can
  be compared with the results of [[char-at]]: `(== c (ch \\>))`."
  [c]
  (long c))

(defn char-at
  "The UTF-16 code unit of `s` at index `i`, or -1 when `i` is out of range."
  ^long [^String s ^long i]
  (if (and (>= i 0) (< i (.length s)))
    (long (int (.charAt s (int i))))
    -1))

;; ---------------------------------------------------------------------------
;; Character classes
;; ---------------------------------------------------------------------------

(defn ws?
  "True for the ASCII whitespace set of the spec: space, TAB, LF, VT, FF, CR."
  [^long c]
  (or (== c 32) (and (>= c 9) (<= c 13))))

(defn space-or-tab?
  [^long c]
  (or (== c 32) (== c 9)))

(defn ascii-punct?
  "True for the 32 ASCII punctuation characters."
  [^long c]
  (or (and (>= c 33) (<= c 47))
      (and (>= c 58) (<= c 64))
      (and (>= c 91) (<= c 96))
      (and (>= c 123) (<= c 126))))

(defn digit?
  [^long c]
  (and (>= c 48) (<= c 57)))

(defn hex-digit?
  [^long c]
  (or (digit? c) (and (>= c 97) (<= c 102)) (and (>= c 65) (<= c 70))))

(defn alpha?
  [^long c]
  (or (and (>= c 97) (<= c 122)) (and (>= c 65) (<= c 90))))

(defn alnum?
  [^long c]
  (or (alpha? c) (digit? c)))

(defn rtrim-ws
  "Remove trailing ASCII whitespace from `s`."
  ^String [^String s]
  (loop [e (.length s)]
    (if (and (pos? e) (ws? (char-at s (dec e))))
      (recur (dec e))
      (if (== e (.length s)) s (.substring s 0 e)))))

(defn trim-ws
  "Remove leading and trailing ASCII whitespace from `s`."
  ^String [^String s]
  (let [n (.length s)
        b (loop [b 0] (if (and (< b n) (ws? (char-at s b))) (recur (inc b)) b))
        e (loop [e n] (if (and (> e b) (ws? (char-at s (dec e)))) (recur (dec e)) e))]
    (if (and (zero? b) (== e n)) s (.substring s b e))))

;; ---------------------------------------------------------------------------
;; Entities and backslash escapes
;; ---------------------------------------------------------------------------

(def ^:private named-entities
  [["amp;" "&"] ["lt;" "<"] ["gt;" ">"] ["quot;" "\""]])

(defn- code-point->string
  ^String [^long cp]
  (if (or (zero? cp) (and (>= cp 0xD800) (<= cp 0xDFFF)) (> cp 0x10FFFF))
    "\uFFFD"
    (String. (Character/toChars (int cp)))))

(defn- numeric-entity
  "Match a numeric reference whose `&` is at `i`. Returns [end code-point] or nil."
  [^String s ^long i]
  (let [n (.length s)
        c2 (char-at s (+ i 2))
        hex? (or (== c2 (ch \x)) (== c2 (ch \X)))
        start (if hex? (+ i 3) (+ i 2))
        max-digits (if hex? 6 7)
        end (loop [k start]
              (let [c (char-at s k)]
                (if (and (< (- k start) max-digits)
                         (if hex? (hex-digit? c) (digit? c)))
                  (recur (inc k))
                  k)))]
    (when (and (> end start) (< end n) (== (char-at s end) (ch \;)))
      [(inc end) (Long/parseLong (.substring s (int start) (int end)) (if hex? 16 10))])))

(defn match-entity
  "If an entity reference starts at index `i` of `s` (where `s[i]` is `&`),
  return `[end replacement-string]`, otherwise nil. Recognised references are
  decimal and hexadecimal numeric ones plus `&amp;`, `&lt;`, `&gt;` and
  `&quot;`."
  [^String s ^long i]
  (if (== (char-at s (inc i)) (ch \#))
    (when-let [[end cp] (numeric-entity s i)]
      [end (code-point->string cp)])
    (some (fn [[^String name ^String rep]]
            (when (.startsWith s name (int (inc i)))
              [(+ i 1 (.length name)) rep]))
          named-entities)))

(defn decode-entities
  "Replace every recognised entity reference in `s` by the character it names."
  ^String [^String s]
  (if (neg? (.indexOf s "&"))
    s
    (let [n (.length s)
          sb (StringBuilder. n)]
      (loop [i 0]
        (when (< i n)
          (if (== (char-at s i) (ch \&))
            (if-let [[end rep] (match-entity s i)]
              (do (.append sb ^String rep) (recur (long end)))
              (do (.append sb \&) (recur (inc i))))
            (do (.append sb (.charAt s (int i))) (recur (inc i))))))
      (.toString sb))))

(defn unescape-backslashes
  "Remove the backslash of every backslash escape (a backslash before an ASCII
  punctuation character) in `s`."
  ^String [^String s]
  (if (neg? (.indexOf s "\\"))
    s
    (let [n (.length s)
          sb (StringBuilder. n)]
      (loop [i 0]
        (when (< i n)
          (if (and (== (char-at s i) (ch \\)) (ascii-punct? (char-at s (inc i))))
            (do (.append sb (.charAt s (int (inc i)))) (recur (+ i 2)))
            (do (.append sb (.charAt s (int i))) (recur (inc i))))))
      (.toString sb))))

(defn clean-string
  "Entity decoding followed by backslash-escape removal, as applied to link
  destinations, link titles and code fence info strings."
  ^String [^String s]
  (unescape-backslashes (decode-entities s)))

;; ---------------------------------------------------------------------------
;; HTML escaping and URL encoding
;; ---------------------------------------------------------------------------

(defn escape-html!
  "Append `s` to the StringBuilder `sb`, escaping `&`, `<`, `>` and `\"`."
  ^StringBuilder [^StringBuilder sb ^String s]
  (let [n (.length s)]
    (loop [i 0 start 0]
      (if (< i n)
        (let [rep (case (.charAt s (int i))
                    \& "&amp;"
                    \< "&lt;"
                    \> "&gt;"
                    \" "&quot;"
                    nil)]
          (if rep
            (do (.append sb s (int start) (int i))
                (.append sb ^String rep)
                (recur (inc i) (inc i)))
            (recur (inc i) start)))
        (.append sb s (int start) (int n)))))
  sb)

(defn escape-html
  "Return `s` with `&`, `<`, `>` and `\"` replaced by character references."
  ^String [^String s]
  (.toString (escape-html! (StringBuilder. (.length s)) s)))

(def ^:private hex-digits "0123456789ABCDEF")

(def ^:private unsafe-schemes ["javascript:" "vbscript:" "file:" "data:"])
(def ^:private safe-data-prefixes
  ["data:image/png" "data:image/gif" "data:image/jpeg" "data:image/webp"])

(defn- starts-with-ci? [^String s ^String prefix]
  (.regionMatches s true 0 prefix 0 (.length prefix)))

(defn unsafe-url?
  "True when `url` uses a scheme that is never emitted as a link target."
  [^String url]
  (boolean
   (and (some #(starts-with-ci? url %) unsafe-schemes)
        (not-any? #(starts-with-ci? url %) safe-data-prefixes))))

(defn- url-safe-byte? [^long b]
  (or (alnum? b)
      (>= (.indexOf "-_.~!#$%()*+,/:;=?@" (int b)) 0)))

(defn encode-url!
  "Append the href attribute value for the link destination `url` to `sb`:
  unsafe schemes give an empty value, safe bytes are copied, `&` and `'` become
  character references and every other UTF-8 byte is percent-encoded."
  ^StringBuilder [^StringBuilder sb ^String url]
  (when-not (unsafe-url? url)
    (let [bs (.getBytes url StandardCharsets/UTF_8)]
      (dotimes [i (alength bs)]
        (let [b (bit-and (long (aget bs i)) 0xFF)]
          (cond
            (url-safe-byte? b) (.append sb (char b))
            (== b 38) (.append sb "&amp;")
            (== b 39) (.append sb "&#x27;")
            :else (doto sb
                    (.append \%)
                    (.append (.charAt ^String hex-digits (int (bit-shift-right b 4))))
                    (.append (.charAt ^String hex-digits (int (bit-and b 15))))))))))
  sb)
