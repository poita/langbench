(ns fulltext.analysis
  "Text analysis: tokenising, case folding, stop words and term extraction.

  Documents and queries go through the same pipeline: *tokenise* the text,
  *fold* each token (drop apostrophes, ASCII lower-case) and turn the folded
  text into an index *term* (Porter-stemmed when it is purely `a`-`z`).

  Offsets are UTF-16 `char` offsets into the source string. Every token
  character lies in the Basic Multilingual Plane, so they select exactly the
  same substrings that code point offsets would."
  (:require [fulltext.stemmer :as stemmer])
  (:import (java.util HashMap)))

(set! *warn-on-reflection* true)

(def whitespace-chars
  "The seven characters treated as whitespace by queries and snippets."
  #{\tab \newline \u000B \u000C \return \space \u00A0})

(defn whitespace?
  "True when `c` (a char) is one of the seven whitespace characters."
  [c]
  (case c
    (\tab \newline \u000B \u000C \return \space \u00A0) true
    false))

(defn token-char?
  "True when code unit `c` (an int) is a token character: ASCII digits and
  letters, Latin-1 letters (minus × and ÷), Latin Extended-A/B, Greek and
  Cyrillic."
  [^long c]
  (or (<= 0x30 c 0x39)
      (<= 0x41 c 0x5A)
      (<= 0x61 c 0x7A)
      (<= 0xC0 c 0xD6)
      (<= 0xD8 c 0xF6)
      (<= 0xF8 c 0x24F)
      (<= 0x370 c 0x3FF)
      (<= 0x400 c 0x4FF)))

(defn apostrophe?
  "True when code unit `c` is U+0027 or U+2019."
  [^long c]
  (or (== c 0x27) (== c 0x2019)))

(def stop-words
  "The 33 stop words, tested against the folded token text before stemming."
  #{"a" "an" "and" "are" "as" "at" "be" "but" "by" "for" "if" "in" "into" "is"
    "it" "no" "not" "of" "on" "or" "such" "that" "the" "their" "then" "there"
    "these" "they" "this" "to" "was" "will" "with"})

(defn stop-word?
  "True when the folded token text `s` is a stop word."
  [s]
  (contains? stop-words s))

(defn token-spans
  "Tokenise `text`. Returns `[starts ends]`, two `int` arrays holding the
  half-open character span of every token, in order. A token is one or more
  token characters, continued by apostrophes that sit directly between two
  token characters."
  [^String text]
  (let [n (.length text)
        starts (java.util.ArrayList.)
        ends (java.util.ArrayList.)]
    (loop [i 0]
      (when (< i n)
        (if (token-char? (int (.charAt text i)))
          (let [end (loop [j (inc i)]
                      (if (< j n)
                        (let [c (int (.charAt text j))]
                          (cond
                            (token-char? c) (recur (inc j))
                            (and (apostrophe? c)
                                 (< (inc j) n)
                                 (token-char? (int (.charAt text (inc j)))))
                            (recur (+ j 2))
                            :else j))
                        j))]
            (.add starts (int i))
            (.add ends (int end))
            (recur (long end)))
          (recur (inc i)))))
    [(int-array starts) (int-array ends)]))

(defn fold
  "Fold token text: delete apostrophes and lower-case `A`-`Z` only."
  ^String [^String s]
  (let [n (.length s)
        sb (StringBuilder. n)]
    (dotimes [i n]
      (let [c (.charAt s i)]
        (cond
          (apostrophe? (int c)) nil
          (<= (int \A) (int c) (int \Z)) (.append sb (char (+ (int c) 32)))
          :else (.append sb c))))
    (.toString sb)))

(defn ascii-lower?
  "True when `s` is non-empty and made only of the letters `a`-`z`."
  [^String s]
  (let [n (.length s)]
    (and (pos? n)
         (loop [i 0]
           (or (== i n)
               (let [c (.charAt s i)]
                 (and (<= (int \a) (int c) (int \z))
                      (recur (inc i)))))))))

(defn term
  "The index term for the folded token text `s`: its Porter stem when `s`
  consists only of `a`-`z`, otherwise `s` itself."
  ^String [^String s]
  (if (ascii-lower? s) (stemmer/stem s) s))

(defn memoizing-term-fn
  "Returns a function equivalent to [[term]] that remembers its results.
  Natural-language vocabularies are small, so this makes stemming almost
  free. The returned function is not thread-safe."
  []
  (let [cache (HashMap.)]
    (fn [^String s]
      (or (.get cache s)
          (let [t (term s)]
            (.put cache s t)
            t)))))

(defn tokenize
  "Tokenise and fold `text`. Returns a map with
  - `:starts`, `:ends` — `int` arrays of token character spans,
  - `:texts` — an `Object` array of folded token texts."
  [^String text]
  (let [[^ints starts ^ints ends] (token-spans text)
        n (alength starts)
        texts (object-array n)]
    (dotimes [i n]
      (aset texts i (fold (.substring text (aget starts i) (aget ends i)))))
    {:starts starts :ends ends :texts texts}))

(defn analyze
  "Analyse `text` into a vector of `{:text folded-text :term term}` maps, one
  per token. Convenient for queries and the REPL; the indexer works on the
  arrays from [[tokenize]] instead."
  [text]
  (let [{:keys [^objects texts]} (tokenize text)]
    (mapv (fn [t] {:text t :term (term t)}) texts)))

(defn atom-terms
  "The search atom for a phrase body: a vector of terms, or `nil` when the
  atom is empty — no tokens at all, or a single token that is a stop word."
  [text]
  (let [toks (analyze text)]
    (cond
      (empty? toks) nil
      (and (== 1 (count toks)) (stop-word? (:text (first toks)))) nil
      :else (mapv :term toks))))
