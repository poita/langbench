(ns mime.rfc2047
  "RFC 2047 encoded words and the whitespace rules for unstructured text.

  [[decode-unstructured]] is used for header values in general;
  [[decode-display]] additionally understands comments and quoted strings and
  is used for the display-name part of addresses."
  (:require [mime.charset :as charset]
            [mime.text :as text]
            [mime.transfer :as transfer])
  (:import (java.io ByteArrayOutputStream)))

(set! *warn-on-reflection* true)

(defn- q-decode
  "Bytes of the Q-encoded text `t`: `_` is a space, `=HH` is a byte and any
  other character contributes its UTF-8 encoding."
  ^bytes [^String t]
  (let [out (ByteArrayOutputStream.)
        n (.length t)]
    (loop [i 0]
      (when (< i n)
        (let [c (.charAt t i)]
          (cond
            (= c \_) (do (.write out 0x20) (recur (inc i)))
            (and (= c \=) (< (+ i 2) n)
                 (>= (text/hex-val (int (.charAt t (+ i 1)))) 0)
                 (>= (text/hex-val (int (.charAt t (+ i 2)))) 0))
            (do (.write out (int (+ (* 16 (text/hex-val (int (.charAt t (+ i 1)))))
                                    (text/hex-val (int (.charAt t (+ i 2)))))))
                (recur (+ i 3)))
            :else
            (let [cp (.codePointAt t i)
                  len (Character/charCount cp)]
              (.write out (charset/encode-utf8 (.substring t i (+ i len))))
              (recur (+ i len)))))))
    (.toByteArray out)))

(defn- no-blank?
  [^String s ^long from ^long to]
  (loop [i from]
    (cond (>= i to) true
          (text/ws? (.charAt s i)) false
          :else (recur (inc i)))))

(defn encoded-word-at
  "If an encoded word starts at index `i` of `v`, returns `[end text]` where
  `end` is the index just after it and `text` its decoded text; otherwise nil."
  [^String v ^long i]
  (let [n (.length v)]
    (when (and (< (inc i) n) (= (.charAt v i) \=) (= (.charAt v (inc i)) \?))
      (let [j (.indexOf v "?" (int (+ i 2)))]
        (when (and (> j (+ i 2))                    ; non-empty charset field
                   (no-blank? v (+ i 2) j)
                   (< (+ j 2) n)
                   (= (.charAt v (+ j 2)) \?))
          (let [enc (.charAt v (inc j))]
            (when (contains? #{\Q \q \B \b} enc)
              (let [m (.indexOf v "?" (int (+ j 3)))]
                (when (and (>= m 0)
                           (no-blank? v (+ j 3) m)
                           (< (inc m) n)
                           (= (.charAt v (inc m)) \=))
                  (let [cs (.substring v (int (+ i 2)) (int j))
                        cs (let [k (.indexOf cs "*")] (if (>= k 0) (.substring cs 0 k) cs))
                        cs (charset/normalize-name cs)
                        cs (if (zero? (.length cs)) "us-ascii" cs)
                        body (.substring v (int (+ j 3)) (int m))
                        bs (if (contains? #{\Q \q} enc)
                             (q-decode body)
                             (transfer/decode-base64-string body))]
                    [(+ m 2) (charset/decode bs cs)]))))))))))

(defn- scan-items
  "Splits `s` into a vector of `[kind text]` items, kind being :enc, :space
  or :lit. With `display?` true, comments become a one-space :space item and
  quoted strings a :lit item holding their unescaped contents."
  [^String s display?]
  (let [n (.length s)]
    (loop [i 0 items [] kind nil start 0]
      (let [flush (fn [items end] (if kind (conj items [kind (.substring s (int start) (int end))]) items))]
        (if (>= i n)
          (flush items n)
          (let [c (.charAt s i)
                ew (when (= c \=) (encoded-word-at s i))]
            (cond
              ew (recur (long (first ew)) (conj (flush items i) [:enc (second ew)]) nil 0)
              (and display? (= c \())
              (recur (text/skip-comment s i) (conj (flush items i) [:space " "]) nil 0)
              (and display? (= c \"))
              (let [[content end] (text/scan-quoted s i)]
                (recur (long end) (conj (flush items i) [:lit content]) nil 0))
              (text/ws? c) (if (= kind :space)
                             (recur (inc i) items kind start)
                             (recur (inc i) (flush items i) :space i))
              :else (if (= kind :lit)
                      (recur (inc i) items kind start)
                      (recur (inc i) (flush items i) :lit i)))))))))

(defn- join-items
  ^String [items]
  (let [v (vec items)
        n (count v)
        sb (StringBuilder.)]
    (dotimes [k n]
      (let [[kind t] (v k)]
        (when-not (and (= kind :space)
                       (> k 0) (< (inc k) n)
                       (= :enc (first (v (dec k))))
                       (= :enc (first (v (inc k)))))
          (.append sb ^String t))))
    (text/strip (.toString sb))))

(defn decode-unstructured
  "Decodes the RFC 2047 encoded words in `v`. Blanks between two adjacent
  encoded words vanish; all other blanks are kept; the result is stripped."
  ^String [^String v]
  (if (neg? (.indexOf v "=?"))
    (text/strip v)
    (join-items (scan-items v false))))

(defn decode-display
  "Like [[decode-unstructured]] but for an address phrase: comments become a
  single space and quoted strings are taken literally (their encoded words are
  not decoded)."
  ^String [^String v]
  (join-items (scan-items v true)))
