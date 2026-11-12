(ns regex.core
  "A small backtracking regular-expression engine with Perl-style leftmost,
  greedy, ordered-choice semantics, written from scratch (it does not use
  java.util.regex).

  Supported syntax: literals, `.`, `^`, `$`, classes `[a-z_] [^...]`, escapes
  `\\d \\w \\s \\D \\W \\S` and escaped punctuation, capturing groups `( )`,
  alternation `|`, and the greedy quantifiers `* + ? {n} {n,} {n,m}`.

      (require '[regex.core :as re])
      (re/match (re/compile \"(a|ab)(c|bcd)(d*)\") \"abcd\")
      ;; => {:start 0, :end 4, :groups [[0 1] [1 4] [4 4]]}

  Matching is recursive: it needs a few stack frames per subject character
  that the pattern consumes inside a repeated group. For long subjects run it
  with a large stack, e.g. via `call-with-stack-size`."
  (:refer-clojure :exclude [compile])
  (:require [regex.analysis :as analysis]
            [regex.compiler :as compiler]
            [regex.parser :as parser])
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)

(defrecord Pattern [source groups step state-size first-set anchored?])

(defn compile
  "Compile a pattern string into a reusable, thread-safe `Pattern`. Throws
  `ex-info` if the pattern is syntactically invalid."
  [^String pattern]
  (let [{:keys [ast groups]} (parser/parse pattern)
        {:keys [step state-size]} (compiler/compile-ast ast groups)
        {:keys [set nullable?]} (analysis/first-info ast)]
    (->Pattern pattern groups step state-size
               (when-not nullable? set)
               (analysis/anchored-start? ast))))

(defn group-count
  "Number of capturing groups in a compiled pattern."
  [^Pattern p] (long (:groups p)))

(defn- try-at
  "Attempt a match starting exactly at `start`; returns the state array on
  success, nil on failure."
  [^Pattern p ^String s ^longs st ^long start]
  (when (.run ^regex.compiler.Step (.-step p) s st start)
    st))

(defn match
  "Find the first (leftmost, then priority-ordered) match of compiled pattern
  `p` in string `s`. Returns nil when there is none, otherwise a map

      {:start n, :end n, :groups [[gs ge] | nil, ...]}

  with one entry per capture group, nil for groups that did not take part in
  the match. Offsets are 0-based; ends are exclusive."
  [^Pattern p ^String s]
  (let [groups (long (.-groups p))
        len (.length s)
        ^longs st (long-array (.-state-size p))
        ^booleans fs (.-first-set p)
        last-start (if (.-anchored? p) 0 len)]
    (Arrays/fill st 0 (int (* 2 groups)) -1)
    (loop [start 0]
      (when (<= start last-start)
        (if (and fs (or (== start len)
                        (let [c (long (int (.charAt s start)))]
                          (not (and (< c 128) (aget fs c))))))
          (recur (unchecked-inc start))
          (if (try-at p s st start)
            {:start start
             :end (aget st (compiler/end-index groups))
             :groups (mapv (fn [g]
                             (let [k (compiler/caps-index g)
                                   gs (aget st k)]
                               (when-not (neg? gs) [gs (aget st (inc k))])))
                           (range 1 (inc groups)))}
            (recur (unchecked-inc start))))))))

(defn re-match
  "Convenience: compile `pattern` and match it against `s`."
  [pattern s]
  (match (compile pattern) s))

(defn call-with-stack-size
  "Call the function `f` of no arguments on a new thread with a stack of
  `bytes` bytes, wait for it, and return its result (rethrowing anything it
  throws). Use it to match against very long subjects."
  [bytes f]
  (let [result (promise)
        t (Thread. nil
                   (fn []
                     (deliver result (try {:value (f)}
                                          (catch Throwable e {:error e}))))
                   "regex-matcher"
                   (long bytes))]
    (.start t)
    (let [{:keys [value error]} @result]
      (if error (throw error) value))))
