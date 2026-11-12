(ns regex.core
  "A backtracking regular-expression engine for a small Perl-style subset.

  Semantics are leftmost, greedy, ordered-choice; see the project README for
  the supported syntax.  Typical use:

      (require '[regex.core :as re])

      (def r (re/compile \"(a|ab)(c|bcd)(d*)\"))
      (re/find-match r \"abcd\")
      ;=> {:start 0, :end 4, :groups [[0 1] [1 4] [4 4]]}

  A compiled regex is immutable and safe to share between threads."
  (:refer-clojure :exclude [compile])
  (:require [regex.analysis :as analysis]
            [regex.compiler :as compiler]
            [regex.parser :as parser]
            [regex.vm :as vm]))

(defrecord Regex [pattern group-count program])

(defn compile
  "Compiles `pattern` (a string) into a Regex.  Throws an ex-info with
  `:type :regex.parser/syntax-error` when the pattern is invalid."
  [^String pattern]
  (let [{:keys [ast groups]} (parser/parse pattern)
        compiled (compiler/compile-ast ast groups)
        prog (vm/program compiled groups
                         (analysis/first-set ast)
                         (analysis/nullable? ast)
                         (analysis/start-anchored? ast))]
    (->Regex pattern groups prog)))

(defn group-count
  "The number of capturing groups in a compiled regex."
  [^Regex re]
  (:group-count re))

(defn find-match
  "Finds the first match of `re` in the string `s`.  Returns nil, or a map

      {:start s0 :end e0 :groups [[gs ge] nil [gs ge] ...]}

  with one entry per group, nil for groups that did not participate.
  Offsets are 0-based; ends are exclusive."
  [^Regex re ^String s]
  (let [prog (:program re)
        chars (.toCharArray s)
        out (int-array (vm/result-size prog))]
    (when (vm/search prog (vm/workspace prog) chars (alength chars) out)
      {:start (aget out 0)
       :end (aget out 1)
       :groups (vec (for [g (range (:group-count re))
                          :let [gs (aget out (+ 2 (* 2 g)))]]
                      (when (>= gs 0) [gs (aget out (+ 3 (* 2 g)))])))})))

(defn matches?
  "True when `re` matches anywhere in `s`."
  [re s]
  (some? (find-match re s)))

(defn match-text
  "Like find-match, but returns the matched substrings:

      {:text \"abcd\" :groups [\"a\" \"bcd\" \"\"]}

  with nil for groups that did not participate."
  [re ^String s]
  (when-let [{:keys [start end groups]} (find-match re s)]
    {:text (subs s start end)
     :groups (mapv (fn [g] (when g (subs s (g 0) (g 1)))) groups)}))
