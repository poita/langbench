(ns typeset.hyphenation
  "Liang hyphenation pattern files (`.chp`) and the hyphenation algorithm."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]))

(set! *warn-on-reflection* true)

(defn- strip-line [^String line]
  (let [i (.indexOf line "#")
        s (str/trim (if (neg? i) line (subs line 0 i)))]
    (when-not (str/blank? s) s)))

(defn- parse-pattern
  "Split a pattern like `a1b2c` into [key values]; `values` has `(count key) + 1`
  entries."
  [^String p]
  (let [n (.length p)
        key (StringBuilder.)
        vals (java.util.ArrayList.)]
    (loop [i 0 pending 0]
      (if (< i n)
        (let [c (.charAt p i)]
          (if (Character/isDigit c)
            (recur (inc i) (- (int c) 48))
            (do (.add vals (long pending))
                (.append key c)
                (recur (inc i) 0))))
        (.add vals (long pending))))
    [(str key) (long-array vals)]))

(defn- parse-exception
  "Split `al-go-rithm` into [\"algorithm\" [2 4]]."
  [^String w]
  (loop [i 0 letters 0 out [] sb (StringBuilder.)]
    (if (< i (.length w))
      (let [c (.charAt w i)]
        (if (= c \-)
          (recur (inc i) letters (conj out letters) sb)
          (recur (inc i) (inc letters) out (.append sb c))))
      [(str sb) out])))

(defn parse-patterns
  "Parse the text of a `.chp` file."
  [text]
  (let [recs (map #(str/split % #"[ \t]+" 2) (keep strip-line (str/split-lines text)))
        base {:left 1 :right 1 :patterns {} :exceptions {} :max-key 0}]
    (reduce
     (fn [h [op arg]]
       (case op
         "left"      (assoc h :left (Long/parseLong arg))
         "right"     (assoc h :right (Long/parseLong arg))
         "pattern"   (let [[k v] (parse-pattern arg)]
                       (-> h
                           (assoc-in [:patterns k] v)
                           (update :max-key max (count k))))
         "exception" (let [[k v] (parse-exception arg)]
                       (assoc-in h [:exceptions k] v))
         h))
     base recs)))

(defn load-patterns
  "Load the pattern set named `set-name` from `<data-dir>/hyphen/<set>.chp`."
  [data-dir set-name]
  (parse-patterns (slurp (io/file data-dir "hyphen" (str set-name ".chp"))
                         :encoding "UTF-8")))

(defn load-all
  "Load both pattern sets; returns name -> pattern set."
  [data-dir]
  (into {} (for [n ["english" "minimal"]] [n (load-patterns data-dir n)])))

(defn breaks
  "Permitted break positions of the lowercase all-letter word `s` as a sorted
  vector of `q` (a break after `q` letters), following Liang's algorithm and the
  `left`/`right` minima of the pattern set `hy`."
  [hy ^String s]
  (let [n (.length s)
        left (long (:left hy))
        right (long (:right hy))
        keep? (fn [q] (and (<= left q) (<= q (- n right))))]
    (if-let [ex (get (:exceptions hy) s)]
      (vec (filter keep? ex))
      (let [t (str "." s ".")
            m (.length t)
            v (long-array (inc m))
            patterns (:patterns hy)
            maxk (long (:max-key hy))]
        (dotimes [i m]
          (loop [j (inc i)]
            (when (and (<= j m) (<= (- j i) maxk))
              (when-let [^longs pv (get patterns (subs t i j))]
                (dotimes [k (alength pv)]
                  (aset v (+ i k) (max (aget v (+ i k)) (aget pv k)))))
              (recur (inc j)))))
        (vec (for [q (range 1 n)
                   :when (odd? (aget v (inc q)))
                   :when (keep? q)]
               q))))))
