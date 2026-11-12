(ns fulltext.query
  "The query language: lexer, recursive-descent parser and tree utilities.

  Queries parse to a tree of plain data:

      [:atom [\"term\" ...]]   a (phrase) atom — a vector of terms
      [:not tree]
      [:and [tree ...]]
      [:or  [tree ...]]
      nil                      the empty tree, which matches nothing

  Parsing never fails: malformed input degrades to the best-effort tree
  described in the specification."
  (:require [fulltext.analysis :as analysis]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Lexer

(defn- delimiter? [c]
  (or (analysis/whitespace? c) (= c \() (= c \)) (= c \")))

(defn lex
  "Split query text into tokens: `:lparen`, `:rparen`, `:and`, `:or`, `:not`
  and `[:phrase body]` (a quoted phrase or a bare word, body unanalysed)."
  [^String s]
  (let [n (.length s)]
    (loop [i 0 out (transient [])]
      (if (>= i n)
        (persistent! out)
        (let [c (.charAt s i)]
          (cond
            (analysis/whitespace? c) (recur (inc i) out)
            (= c \() (recur (inc i) (conj! out :lparen))
            (= c \)) (recur (inc i) (conj! out :rparen))
            (= c \")
            (let [close (.indexOf s "\"" (int (inc i)))
                  end (if (neg? close) n close)]
              (recur (long (if (neg? close) n (inc close)))
                     (conj! out [:phrase (.substring s (inc i) end)])))
            :else
            (let [end (loop [j (inc i)]
                        (if (and (< j n) (not (delimiter? (.charAt s j))))
                          (recur (inc j))
                          j))
                  word (.substring s i end)]
              (recur (long end)
                     (conj! out (case word
                                  "AND" :and
                                  "OR" :or
                                  "NOT" :not
                                  [:phrase word]))))))))))

;; ---------------------------------------------------------------------------
;; Parser. Each parse function takes the token vector and a position and
;; returns [tree next-position].

(declare parse-or)

(defn- combine
  "Combine non-empty child trees under `op` (`:and` / `:or`)."
  [op children]
  (let [kids (filterv some? children)]
    (case (count kids)
      0 nil
      1 (first kids)
      [op kids])))

(defn- parse-primary [tokens ^long pos]
  (if (>= pos (count tokens))
    [nil pos]
    (let [t (nth tokens pos)]
      (cond
        (= t :lparen)
        (let [[tree p] (parse-or tokens (inc pos))]
          [tree (if (and (< p (count tokens)) (= :rparen (nth tokens p)))
                  (inc p)
                  p)])

        (= t :rparen) [nil pos]

        (vector? t)
        (let [terms (analysis/atom-terms (second t))]
          [(when terms [:atom terms]) (inc pos)])

        :else [nil (inc pos)]))))

(defn- parse-not [tokens ^long pos]
  (let [n (count tokens)
        [nots p] (loop [k 0 p pos]
                   (if (and (< p n) (= :not (nth tokens p)))
                     (recur (inc k) (inc p))
                     [k p]))
        [tree p] (parse-primary tokens p)]
    [(when tree (nth (iterate (fn [t] [:not t]) tree) nots)) p]))

(defn- parse-and [tokens ^long pos]
  (let [n (count tokens)]
    (loop [p pos kids []]
      (if (or (>= p n) (#{:rparen :or} (nth tokens p)))
        [(combine :and kids) p]
        (if (= :and (nth tokens p))
          (recur (inc p) kids)
          (let [[tree p'] (parse-not tokens p)]
            (recur (long p') (conj kids tree))))))))

(defn- parse-or [tokens ^long pos]
  (let [n (count tokens)
        [first-tree p] (parse-and tokens pos)]
    (loop [p p kids [first-tree]]
      (if (and (< p n) (= :or (nth tokens p)))
        (let [[tree p'] (parse-and tokens (inc p))]
          (recur (long p') (conj kids tree)))
        [(combine :or kids) p]))))

(defn parse
  "Parse query text into a tree (see the namespace docs). The empty tree is
  `nil`. Never throws."
  [text]
  (first (parse-or (lex text) 0)))

;; ---------------------------------------------------------------------------
;; Tree utilities

(defn positive-atoms
  "The positive atoms of `tree` — those under an even number of `:not`s — as
  a vector of term vectors, in depth-first left-to-right order of first
  appearance, without duplicates."
  [tree]
  (letfn [(walk [t positive? acc]
            (if (nil? t)
              acc
              (case (first t)
                :atom (if positive? (conj acc (second t)) acc)
                :not (walk (second t) (not positive?) acc)
                (reduce (fn [a c] (walk c positive? a)) acc (second t)))))]
    (vec (distinct (walk tree true [])))))

(defn atoms
  "All distinct atoms of `tree`, positive or negative, as term vectors."
  [tree]
  (letfn [(walk [t acc]
            (if (nil? t)
              acc
              (case (first t)
                :atom (conj acc (second t))
                :not (walk (second t) acc)
                (reduce (fn [a c] (walk c a)) acc (second t)))))]
    (vec (distinct (walk tree [])))))
