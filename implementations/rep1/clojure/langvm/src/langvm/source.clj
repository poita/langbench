(ns langvm.source
  "Splitting the input stream into modules (SPEC section 2)."
  (:require [clojure.string :as str]
            [langvm.diag :as diag]))

(set! *warn-on-reflection* true)

(def keywords
  #{"as" "break" "continue" "else" "enum" "false" "fn" "for" "if" "impl" "in"
    "let" "match" "pub" "return" "self" "struct" "trait" "true" "use" "var"
    "when" "while"})

(defn identifier?
  "True when `s` is a legal identifier (not a keyword, not `_`, <= 200 chars)."
  [^String s]
  (boolean
   (and (<= 1 (.length s) 200)
        (re-matches #"[A-Za-z_][A-Za-z0-9_]*" s)
        (not= s "_")
        (not (keywords s)))))

(defn split-lines
  "Split `text` at LF; a CR directly before the LF is dropped.  The final line
  need not be terminated and an empty text has no lines."
  [^String text]
  (if (zero? (.length text))
    []
    (let [n (.length text)
          out (java.util.ArrayList.)]
      (loop [start 0]
        (let [nl (.indexOf text (int 10) (int start))]
          (cond
            (neg? nl)
            (do (when (< start n) (.add out (.substring text start n)))
                (vec out))
            :else
            (let [end (if (and (> nl start) (= \return (.charAt text (dec nl))))
                        (dec nl) nl)]
              (.add out (.substring text start end))
              (recur (inc nl)))))))))

(defn- header-name
  "The module name when `line` is a valid module header, else nil."
  [^String line]
  (when (.startsWith line "@module ")
    (let [name (subs line 8)]
      (when (identifier? name) name))))

(defn split-modules
  "Split `text` into a vector of `{:name :lines :header-line}` maps, or signal
  `bad-module` / `dup-module`."
  [text]
  (let [lines (split-lines text)]
    (when (or (empty? lines) (not (header-name (first lines))))
      (diag/fail :bad-module (diag/pos 1 1)))
    (let [mods
          (loop [i 0, cur nil, acc []]
            (if (= i (count lines))
              (conj acc cur)
              (let [^String l (nth lines i)]
                (cond
                  (header-name l)
                  (recur (inc i)
                         {:name (header-name l) :lines [] :header-line (inc i)}
                         (if cur (conj acc cur) acc))
                  (and (pos? (.length l)) (= \@ (.charAt l 0)))
                  (diag/fail :bad-module (diag/pos (inc i) 1))
                  :else
                  (recur (inc i) (update cur :lines conj l) acc)))))]
      (reduce (fn [seen m]
                (when (seen (:name m))
                  (diag/fail :dup-module (diag/pos (:header-line m) 1)))
                (conj seen (:name m)))
              #{} mods)
      mods)))
