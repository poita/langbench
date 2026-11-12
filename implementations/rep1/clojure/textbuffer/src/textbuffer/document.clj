(ns textbuffer.document
  "The text of a buffer: a sequence of lines.

  A document is a vector-like store of line strings (at least one line; an
  empty document is a single empty line). Positions are packed longs, see
  [[textbuffer.position]].

  Documents follow the same discipline as Clojure's transients. A document
  obtained from [[document]] or [[freeze]] is a value and must not be changed.
  To edit, take a private copy with [[thaw]], apply any number of
  [[replace!]] calls, and publish the result with [[freeze]]; the thawed
  document must not be used after it has been frozen. Thawing costs O(L)
  (a copy of the line references); each [[replace!]] costs O(line length +
  inserted text), plus O(L) when the number of lines changes."
  (:require [textbuffer.position :as p])
  (:import (java.util ArrayList List)
           (java.util.concurrent.atomic AtomicBoolean)))

(set! *warn-on-reflection* true)

(deftype Document [^ArrayList lines ^AtomicBoolean editable]
  Object
  (toString [_] (String/join "\n" ^Iterable lines)))

(defn document
  "Creates a (frozen) document from a collection of line strings. An empty
  collection gives the empty document, one empty line."
  [lines]
  (let [^java.util.Collection src (if (seq lines) lines [""])
        al (ArrayList. src)]
    (->Document al (AtomicBoolean. false))))

(defn from-text
  "Creates a document from text whose lines are separated by `\\n`."
  [^String text]
  (let [al (ArrayList.)]
    (loop [from 0]
      (let [i (.indexOf text 10 (int from))]
        (if (neg? i)
          (.add al (.substring text from))
          (do (.add al (.substring text from i))
              (recur (inc i))))))
    (->Document al (AtomicBoolean. false))))

(defn line-count
  "Number of lines, always at least 1."
  ^long [^Document d]
  (.size ^ArrayList (.-lines d)))

(defn line-text
  "The text of line `i` (without a newline)."
  ^String [^Document d i]
  (.get ^ArrayList (.-lines d) (int i)))

(defn line-length
  "Number of characters in line `i`."
  ^long [^Document d ^long i]
  (.length (line-text d i)))

(defn lines
  "The lines of the document as a vector of strings."
  [^Document d]
  (vec (.-lines d)))

(defn text
  "The whole document as one string, lines joined by `\\n`."
  ^String [^Document d]
  (.toString d))

(defn end-position
  "The position at the very end of the document."
  ^long [^Document d]
  (let [last-line (dec (line-count d))]
    (p/pos last-line (line-length d last-line))))

(defn clamp
  "Clamps `line` into `[0, L-1]`, then `col` into `[0, len(line)]`, and
  returns the packed position."
  ^long [^Document d ^long line ^long col]
  (let [l (-> line (clojure.core/max 0) (clojure.core/min (dec (line-count d))))
        c (-> col (clojure.core/max 0) (clojure.core/min (line-length d l)))]
    (p/pos l c)))

(defn slice
  "The text between positions `from` and `to` (`from <= to`); lines are
  joined by `\\n`."
  ^String [^Document d from to]
  (let [from (long from) to (long to)
        fl (p/line from) fc (p/col from)
        tl (p/line to) tc (p/col to)]
    (if (== fl tl)
      (.substring (line-text d fl) fc tc)
      (let [sb (StringBuilder.)]
        (.append sb (line-text d fl) (int fc) (.length (line-text d fl)))
        (loop [i (inc fl)]
          (when (< i tl)
            (.append sb \newline)
            (.append sb (line-text d i))
            (recur (inc i))))
        (.append sb \newline)
        (.append sb (line-text d tl) 0 (int tc))
        (.toString sb)))))

;; ---------------------------------------------------------------------------
;; Transient-style editing

(defn thaw
  "Returns an editable copy of `d`; `d` itself is untouched."
  ^Document [^Document d]
  (->Document (ArrayList. ^java.util.Collection (.-lines d)) (AtomicBoolean. true)))

(defn freeze
  "Ends editing: `d` (a thawed document) becomes an immutable value and must
  not be edited or used as a working copy again. Returns `d`; O(1)."
  ^Document [^Document d]
  (.set ^AtomicBoolean (.-editable d) false)
  d)

(defn- split-lines
  "Splits `text` at `\\n` into an ArrayList of at least one string."
  ^ArrayList [^String text]
  (let [parts (ArrayList.)]
    (loop [from 0]
      (let [i (.indexOf text 10 (int from))]
        (if (neg? i)
          (.add parts (.substring text from))
          (do (.add parts (.substring text from i))
              (recur (inc i))))))
    parts))

(defn replace!
  "Replaces the text between positions `from` and `to` (`from <= to`) of the
  thawed document `d` with `new-text`, which may contain `\\n`. Returns `d`."
  ^Document [^Document d ^long from ^long to ^String new-text]
  (when-not (.get ^AtomicBoolean (.-editable d))
    (throw (IllegalStateException. "document is not editable: thaw it first")))
  (let [^ArrayList ls (.-lines d)
        fl (int (p/line from)) fc (int (p/col from))
        tl (int (p/line to)) tc (int (p/col to))
        ^String first-line (.get ls fl)
        ^String last-line (if (== fl tl) first-line (.get ls tl))
        multi? (>= (.indexOf new-text 10) 0)]
    (if-not multi?
      (let [sb (StringBuilder. (+ fc (.length new-text) (- (.length last-line) tc)))]
        (.append sb first-line 0 fc)
        (.append sb new-text)
        (.append sb last-line tc (.length last-line))
        (.set ls fl (.toString sb))
        (when (< fl tl)
          (.clear (.subList ls (inc fl) (inc tl)))))
      (let [parts (split-lines new-text)
            n (.size parts)
            head (doto (StringBuilder.)
                   (.append first-line 0 fc)
                   (.append ^String (.get parts 0)))
            tail (doto (StringBuilder.)
                   (.append ^String (.get parts (dec n)))
                   (.append last-line tc (.length last-line)))]
        (.set parts 0 (.toString head))
        (.set parts (dec n) (.toString tail))
        ;; parts now holds the replacement lines for lines fl..tl
        (.set ls fl (.get parts 0))
        (let [^List removing (.subList ls (inc fl) (inc tl))]
          (.clear removing))
        (.addAll ls (inc fl) (.subList parts 1 n))))
    d))
