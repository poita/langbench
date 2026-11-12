(ns typeset.metrics
  "Font metric files (`.cfm`): loading, glyph measurement and face resolution."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [typeset.util :as u]))

(set! *warn-on-reflection* true)

(def face-names
  ["serif" "serif-bold" "serif-italic" "serif-bold-italic"
   "sans" "sans-bold" "sans-italic" "sans-bold-italic" "mono"])

(defn- strip-line
  "Remove a `#` comment and surrounding blanks; nil when nothing remains."
  [^String line]
  (let [i (.indexOf line "#")
        s (str/trim (if (neg? i) line (subs line 0 i)))]
    (when-not (str/blank? s) s)))

(defn- parse-long* [s] (Long/parseLong s))

(defn parse-face
  "Parse the text of a `.cfm` file into a face map:
  `{:name :ascent :descent :space :stretch :shrink :extra :default :adv :kern}`
  where `:adv` maps a code point to its advance and `:kern` maps a packed pair
  (see [[kern-key]]) to a kern, all in 1/1000 em."
  [text]
  (reduce
   (fn [face line]
     (let [[op & args] (str/split line #"[ \t]+")]
       (case op
         "cfm"     face
         "face"    (assoc face :name (first args))
         "ascent"  (assoc face :ascent (parse-long* (first args)))
         "descent" (assoc face :descent (parse-long* (first args)))
         "space"   (let [[a s h] (map parse-long* args)]
                     (assoc face :space a :stretch s :shrink h))
         "extra"   (assoc face :extra (parse-long* (first args)))
         "default" (assoc face :default (parse-long* (first args)))
         "glyph"   (assoc-in face [:adv (parse-long* (first args))]
                             (parse-long* (second args)))
         "kern"    (let [[a b k] (map parse-long* args)]
                     (assoc-in face [:kern (bit-or (bit-shift-left a 24) b)] k))
         face)))
   {:adv {} :kern {}}
   (keep strip-line (str/split-lines text))))

(defn load-faces
  "Load the nine faces from `<data-dir>/faces/*.cfm`; returns name -> face."
  [data-dir]
  (into {}
        (for [n face-names]
          [n (parse-face (slurp (io/file data-dir "faces" (str n ".cfm"))
                                :encoding "UTF-8"))])))

(defn face-name
  "Resolve (family, bold, italic) to a face name; `family` is a keyword or string."
  [family bold italic]
  (let [f (name family)]
    (if (= f "mono")
      "mono"
      (str f (when bold "-bold") (when italic "-italic")))))

(defn advance
  "Advance of code point `c` in 1/1000 em."
  ^long [face ^long c]
  (long (get (:adv face) c (:default face))))

(defn kern
  "Kern between code points `a` and `b` in 1/1000 em (0 when absent)."
  ^long [face ^long a ^long b]
  (long (get (:kern face) (bit-or (bit-shift-left a 24) b) 0)))

(defn text-units
  "Glyph-space width of code points `from`..`to` of `cps`: the advances plus the
  kerns between adjacent pairs, *not yet scaled*."
  ^long [face ^ints cps ^long from ^long to]
  (loop [i from acc 0]
    (if (< i to)
      (let [c (aget cps i)
            acc (+ acc (advance face c))]
        (recur (inc i)
               (if (< (inc i) to)
                 (+ acc (kern face c (aget cps (inc i))))
                 acc)))
      acc)))

(defn box-width
  "Width in millipoints of a box holding code points `from`..`to` of `cps`
  (a single `scale` of the summed units)."
  [face ^ints cps from to size]
  (u/scale (text-units face cps from to) size))

(defn string-width
  "Width in millipoints of string `s` set as one box of `face` at `size`."
  ^long [face ^String s ^long size]
  (let [cps (u/code-points s)]
    (box-width face cps 0 (alength cps) size)))

(defn ascent ^long [face ^long size] (u/scale (:ascent face) size))
(defn descent ^long [face ^long size] (u/scale (:descent face) size))
