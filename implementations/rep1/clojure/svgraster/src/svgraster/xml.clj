(ns svgraster.xml
  "A tiny non-validating XML reader: just enough of XML for SVG documents.

  Only elements and attributes are kept. Processing instructions, comments,
  DOCTYPE declarations, CDATA sections and character data are skipped.
  Namespace prefixes are stripped from element and attribute names.

  An element is a map `{:tag \"rect\", :attrs {\"x\" \"1\"}, :children [...]}`."
  (:import (java.lang StringBuilder)))

(set! *warn-on-reflection* true)

(def ^:private named-entities
  {"amp" "&" "lt" "<" "gt" ">" "quot" "\"" "apos" "'"})

(defn decode-entities
  "Resolves `&amp; &lt; &gt; &quot; &apos;` and numeric character references
  (`&#65;`, `&#x41;`) in `s`. Any other `&...;` sequence is left as is."
  ^String [^String s]
  (if (neg? (.indexOf s "&"))
    s
    (let [n (.length s)
          sb (StringBuilder.)]
      (loop [i 0]
        (when (< i n)
          (let [c (.charAt s i)]
            (if (= c \&)
              (let [semi (.indexOf s ";" (int i))
                    ent (when (and (pos? semi) (<= (- semi i) 12))
                          (subs s (inc i) semi))
                    named (some-> ent named-entities)
                    cp (when (and ent (not named) (seq ent) (= (first ent) \#))
                         (try
                           (if (#{\x} (second ent))
                             (Integer/parseInt (subs ent 2) 16)
                             (Integer/parseInt (subs ent 1) 10))
                           (catch NumberFormatException _ nil)))]
                (cond
                  named (do (.append sb ^String named) (recur (inc semi)))
                  (and cp (Character/isValidCodePoint (int cp)))
                  (do (.appendCodePoint sb (int cp)) (recur (inc semi)))
                  :else (do (.append sb c) (recur (inc i)))))
              (do (.append sb c) (recur (inc i)))))))
      (.toString sb))))

(defn- strip-prefix
  "`xlink:href` -> `href`."
  ^String [^String name]
  (let [i (.lastIndexOf name ":")]
    (if (neg? i) name (subs name (inc i)))))

(defn- ws? [c] (or (= c \space) (= c \tab) (= c \newline) (= c \return)))

(defn- skip-ws ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [i i]
      (if (and (< i n) (ws? (.charAt s i))) (recur (inc i)) i))))

(defn- index-after
  "Index just after the next occurrence of `token` at or after `i`, or the end
  of the string."
  ^long [^String s ^String token ^long i]
  (let [j (.indexOf s token (int i))]
    (if (neg? j) (.length s) (+ j (.length token)))))

(defn- skip-declaration
  "Skips a `<!DOCTYPE ...>` style declaration starting at `i` (which points at
  `<!`), honouring quotes and an internal `[...]` subset."
  ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [i (+ i 2) depth 0 quote nil]
      (if (>= i n)
        n
        (let [c (.charAt s i)]
          (cond
            quote (recur (inc i) depth (when (not= c quote) quote))
            (or (= c \") (= c \')) (recur (inc i) depth c)
            (= c \[) (recur (inc i) (inc depth) nil)
            (= c \]) (recur (inc i) (dec depth) nil)
            (and (= c \>) (<= depth 0)) (inc i)
            :else (recur (inc i) depth nil)))))))

(defn- parse-attrs
  "Parses the attributes of a start tag whose name ended at `i`. Returns
  `[attrs self-closing? next-index]`."
  [^String s ^long i]
  (let [n (.length s)]
    (loop [i i attrs {}]
      (let [i (skip-ws s i)]
        (if (>= i n)
          [attrs false n]
          (let [c (.charAt s i)]
            (cond
              (= c \>) [attrs false (inc i)]
              (= c \/) (let [j (index-after s ">" i)] [attrs true j])
              :else
              (let [j (loop [j i]
                        (if (and (< j n)
                                 (let [d (.charAt s j)]
                                   (not (or (ws? d) (= d \=) (= d \>) (= d \/)))))
                          (recur (inc j))
                          j))
                    name (strip-prefix (subs s i j))
                    j (skip-ws s j)]
                (if (and (< j n) (= (.charAt s j) \=))
                  (let [j (skip-ws s (inc j))]
                    (if (and (< j n) (let [q (.charAt s j)] (or (= q \") (= q \'))))
                      (let [q (.charAt s j)
                            end (.indexOf s (int q) (int (inc j)))
                            end (if (neg? end) n end)
                            value (decode-entities (subs s (inc j) end))]
                        (recur (min n (inc end)) (assoc attrs name value)))
                      (recur j attrs)))
                  ;; attribute without a value: ignore it
                  (recur (if (= j i) (inc j) j) attrs))))))))))

(defn- close-all
  "Closes every element still open at the end of the input (truncated file)."
  [stack]
  (when (empty? stack)
    (throw (ex-info "no document element" {})))
  (let [[tag attrs kids] (peek stack)
        el {:tag tag :attrs attrs :children kids}
        stack (pop stack)]
    (if (empty? stack)
      el
      (let [[ptag pattrs pkids] (peek stack)]
        (recur (conj (pop stack) [ptag pattrs (conj pkids el)]))))))

(defn parse
  "Parses the XML text `s` and returns the document element (the first start
  tag) as `{:tag :attrs :children}`. Throws `ex-info` when there is none."
  [^String s]
  (let [n (.length s)]
    (loop [i 0 stack []]
      (if (>= i n)
        (close-all stack)
        (let [lt (.indexOf s "<" (int i))]
          (if (neg? lt)
            (close-all stack)
            (cond
              (.startsWith s "<?" (int lt)) (recur (index-after s "?>" lt) stack)
              (.startsWith s "<!--" (int lt)) (recur (index-after s "-->" (+ lt 4)) stack)
              (.startsWith s "<![CDATA[" (int lt)) (recur (index-after s "]]>" lt) stack)
              (.startsWith s "<!" (int lt)) (recur (skip-declaration s lt) stack)
              (.startsWith s "</" (int lt))
              (let [j (index-after s ">" lt)]
                (if (empty? stack)
                  (recur j stack)
                  (let [[tag attrs kids] (peek stack)
                        el {:tag tag :attrs attrs :children kids}
                        stack (pop stack)]
                    (if (empty? stack)
                      el
                      (let [[ptag pattrs pkids] (peek stack)]
                        (recur j (conj (pop stack) [ptag pattrs (conj pkids el)])))))))
              :else
              (let [name-end (loop [j (inc lt)]
                               (if (and (< j n)
                                        (let [d (.charAt s j)]
                                          (not (or (ws? d) (= d \>) (= d \/)))))
                                 (recur (inc j))
                                 j))
                    tag (strip-prefix (subs s (inc lt) name-end))
                    [attrs self-closing? next-i] (parse-attrs s name-end)]
                (if self-closing?
                  (let [el {:tag tag :attrs attrs :children []}]
                    (if (empty? stack)
                      el
                      (let [[ptag pattrs pkids] (peek stack)]
                        (recur (long next-i) (conj (pop stack) [ptag pattrs (conj pkids el)])))))
                  (recur (long next-i) (conj stack [tag attrs []])))))))))))
