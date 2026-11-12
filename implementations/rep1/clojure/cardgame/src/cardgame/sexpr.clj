(ns cardgame.sexpr
  "Reader for the s-expression syntax used by card databases.

  The reader is deliberately tiny: it understands parentheses, `;` comments,
  double-quoted strings (no escapes, no newlines) and atoms.  An atom that
  looks like a decimal integer becomes a `long`; every other atom becomes a
  symbol.  Lists are returned as vectors, strings as Strings.

  All problems are reported by throwing an `ex-info` whose data contains
  `:cardgame/error :bad-database` (see [[bad!]])."
  (:require [clojure.string :as str])
  (:refer-clojure :exclude [read]))

(defn bad!
  "Signal an invalid card database."
  ([] (bad! "invalid card database"))
  ([msg] (throw (ex-info msg {:cardgame/error :bad-database}))))

(defn bad-database?
  "True when `e` is an exception raised by [[bad!]]."
  [e]
  (= :bad-database (:cardgame/error (ex-data e))))

(defn- ws? [^Character c]
  (case c (\space \tab \return \newline \formfeed \u000B) true false))

(defn- delimiter? [^Character c]
  (or (ws? c) (case c (\( \) \; \") true false)))

(def ^:private int-atom #"-?[0-9]+")

(defn- parse-atom [^String s]
  (if (re-matches int-atom s)
    (let [bi (BigInteger. s)]
      (if (< (.bitLength bi) 64)
        (.longValue bi)
        (bad! "integer out of range")))
    (symbol s)))

(defn tokenize
  "Split `text` into a vector of tokens: `:open`, `:close`, `[:str s]` or
  an atom value (long or symbol)."
  [^String text]
  (let [n (.length text)]
    (loop [i 0 out (transient [])]
      (if (>= i n)
        (persistent! out)
        (let [c (.charAt text i)]
          (cond
            (ws? c) (recur (inc i) out)
            (= c \;) (let [j (.indexOf text "\n" i)]
                       (if (neg? j)
                         (persistent! out)
                         (recur (inc j) out)))
            (= c \() (recur (inc i) (conj! out :open))
            (= c \)) (recur (inc i) (conj! out :close))
            (= c \") (let [j (loop [j (inc i)]
                               (cond
                                 (>= j n) (bad! "unterminated string")
                                 (= (.charAt text j) \") j
                                 (= (.charAt text j) \newline) (bad! "newline in string")
                                 :else (recur (inc j))))]
                       (recur (inc j) (conj! out [:str (subs text (inc i) j)])))
            :else (let [j (loop [j (inc i)]
                            (if (and (< j n) (not (delimiter? (.charAt text j))))
                              (recur (inc j))
                              j))]
                    (recur j (conj! out (parse-atom (subs text i j)))))))))))

(defn read-all
  "Read every top-level form of `text`.  Returns a vector of forms."
  [text]
  (let [toks (tokenize text)
        n    (count toks)]
    (letfn [(form [i]
              ;; returns [form next-index]
              (let [t (nth toks i)]
                (cond
                  (= t :open)
                  (loop [j (inc i) acc (transient [])]
                    (when (>= j n) (bad! "unbalanced parentheses"))
                    (if (= (nth toks j) :close)
                      [(persistent! acc) (inc j)]
                      (let [[f j'] (form j)]
                        (recur j' (conj! acc f)))))

                  (= t :close) (bad! "unexpected )")
                  (vector? t) [(second t) (inc i)]
                  :else [t (inc i)])))]
      (loop [i 0 out []]
        (if (>= i n)
          out
          (let [[f i'] (form i)]
            (recur i' (conj out f))))))))

(defn print-form
  "Canonical printing of a form read by [[read-all]]: lists in parentheses
  joined by single spaces, strings in double quotes, integers in minimal
  decimal."
  [f]
  (cond
    (vector? f) (str "(" (str/join " " (map print-form f)) ")")
    (string? f) (str "\"" f "\"")
    :else (str f)))
