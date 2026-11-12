(ns typeset.inline
  "The inline markup scanner. Turns the text of one block into a vector of
  *units* — characters, spaces, rigid spaces, discretionary points and
  footnotes — each carrying the style in force, and reports inline errors.

  A unit is a map with a `:k` of one of

    :char  {:c code-point :st style}
    :space {:st style}            an inter-word space (before collapsing)
    :rigid {:st style}            `~` or `\\ `
    :disc                         `\\-`
    :note  {:n number :st style :units units}
    :gap   {:w width}             a fixed gap (heading number, caption, ...)

  A style is `{:b bool :i bool :m bool :ops [:up | :down ...]}`; the size
  steps are replayed against the context size when the list is built."
  (:require [clojure.string :as str]
            [typeset.util :as u :refer [fail]]))

(set! *warn-on-reflection* true)

(def empty-style {:b false :i false :m false :ops []})

(defn- style-for [style tag]
  (case (char tag)
    \b (assoc style :b true)
    \i (assoc style :i true)
    \m (assoc style :m true)
    \+ (update style :ops conj :up)
    \- (update style :ops conj :down)
    \n style))

(defn normalize
  "Apply the whitespace rules: collapse each run of spaces into one space (that
  of its first member) and drop spaces at the very start and end."
  [units]
  (let [collapsed (loop [us (seq units) out (transient []) prev-space? false]
                    (if us
                      (let [x (first us)]
                        (if (= :space (:k x))
                          (recur (next us) (if prev-space? out (conj! out x)) true)
                          (recur (next us) (conj! out x) false)))
                      (persistent! out)))
        n (count collapsed)
        s (if (and (pos? n) (= :space (:k (first collapsed)))) 1 0)
        e (if (and (> n s) (= :space (:k (peek collapsed)))) (dec n) n)]
    (subvec collapsed s e)))

(defn scan
  "Scan code points `from`..`to` of `cps` as inline text. `lns` and `cols` give
  the source line and column of every code point for error reports.

  Options: `:file`, `:no-notes?` (footnotes forbidden here) and `:next-note!`
  (a function returning the next footnote number)."
  [^ints cps ^ints lns ^ints cols from to {:keys [file no-notes? next-note!]}]
  (let [from (long from) to (long to)
        err (fn [i code] (fail file (aget lns i) (aget cols i) code))]
    (loop [i from units [] style empty-style stack ()]
      (if (>= i to)
        (do (when (seq stack) (err (:pos (first stack)) "unclosed-inline"))
            (normalize units))
        (let [c (aget cps i)]
          (case c
            123 (let [tag (when (< (+ i 2) to) (aget cps (inc i)))]
                  (if (and tag (#{98 105 109 43 45 110} tag) (== 124 (aget cps (+ i 2))))
                    (if (== tag 110)
                      (do (when (some :note stack) (err i "nested-footnote"))
                          (when no-notes? (err i "footnote-not-allowed"))
                          (recur (+ i 3) [] empty-style
                                 (cons {:pos i :saved-style style :saved-units units
                                        :note (next-note!)} stack)))
                      (recur (+ i 3) units (style-for style tag)
                             (cons {:pos i :saved-style style} stack)))
                    (err i "unknown-inline")))
            125 (if (empty? stack)
                  (err i "stray-brace")
                  (let [{:keys [saved-style saved-units note]} (first stack)]
                    (if note
                      (recur (inc i)
                             (conj saved-units {:k :note :n note :st saved-style
                                                :units (normalize units)})
                             saved-style (rest stack))
                      (recur (inc i) units saved-style (rest stack)))))
            92 (let [d (when (< (inc i) to) (aget cps (inc i)))]
                 (cond
                   (nil? d) (err i "bad-escape")
                   (== d 32) (recur (+ i 2) (conj units {:k :rigid :st style}) style stack)
                   (== d 45) (recur (+ i 2) (conj units {:k :disc}) style stack)
                   (#{123 125 124 92 64 126} d)
                   (recur (+ i 2) (conj units {:k :char :c d :st style}) style stack)
                   :else (err i "bad-escape")))
            126 (recur (inc i) (conj units {:k :rigid :st style}) style stack)
            32 (recur (inc i) (conj units {:k :space :st style}) style stack)
            (recur (inc i) (conj units {:k :char :c c :st style}) style stack)))))))

(defn string-units
  "Units for literal text `s` (no markup recognised): every code point is an
  ordinary character and every space a space."
  [^String s]
  (normalize
   (mapv (fn [c] (if (== c 32)
                   {:k :space :st empty-style}
                   {:k :char :c c :st empty-style}))
         (u/code-points s))))

(defn plain-text
  "The plain text of units: footnotes and discretionary points vanish, rigid
  spaces become spaces and runs of spaces collapse; trimmed."
  [units]
  (let [sb (StringBuilder.)]
    (doseq [x units]
      (case (:k x)
        :char (.appendCodePoint sb (int (:c x)))
        (:space :rigid) (.append sb \space)
        nil))
    (-> (str sb) (str/replace #" +" " ") str/trim)))
