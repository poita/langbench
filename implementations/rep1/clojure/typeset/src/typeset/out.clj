(ns typeset.out
  "Output items (what `layout.txt` lists), their formatting and ordering."
  (:require [clojure.string :as str]))

(set! *warn-on-reflection* true)

(def region-rank {:header 0 :float 1 :body 2 :footnote 3 :footer 4})

(defn- quote-string [^String s]
  (str "\"" (-> s (str/replace "\\" "\\\\") (str/replace "\"" "\\\"")) "\""))

(defn text-item
  "A `text` item: left edge `x`, baseline `y`, advance `w`."
  [region face size x y w ^String s]
  {:r (region-rank region) :x x :y y :k 0
   :s (str "text " (name region) " " face " " size " " x " " y " " w " " (quote-string s))})

(defn rule-item
  "A `rule` item: `y` is the top edge."
  [region x y w thick]
  {:r (region-rank region) :x x :y y :k 1
   :s (str "rule " (name region) " " x " " y " " w " " thick)})

(defn box-item
  "A `box` item (a figure frame): `y` is the top edge."
  [region x y w h]
  {:r (region-rank region) :x x :y y :k 2
   :s (str "box " (name region) " " x " " y " " w " " h)})

(defn run-item
  "The `text` item of a placed run `{:text :face :size :raise :x :w}` on
  `baseline`."
  [region {:keys [text face size raise x w]} baseline]
  (text-item region face size x (- baseline raise) w text))

(defn- compare-utf8
  "Compare strings by their UTF-8 bytes, which is code point order."
  ^long [^String a ^String b]
  (let [na (.length a) nb (.length b)]
    (loop [i 0 j 0]
      (cond
        (and (>= i na) (>= j nb)) 0
        (>= i na) -1
        (>= j nb) 1
        :else (let [ca (.codePointAt a i) cb (.codePointAt b j)]
                (if (== ca cb)
                  (recur (+ i (Character/charCount ca)) (+ j (Character/charCount cb)))
                  (if (< ca cb) -1 1)))))))

(defn compare-items [a b]
  (let [c (compare [(:r a) (:y a) (:x a) (:k a)] [(:r b) (:y b) (:x b) (:k b)])]
    (if (zero? c) (compare-utf8 (:s a) (:s b)) c)))

(defn sorted-lines
  "The formatted lines of `items` in output order."
  [items]
  (mapv :s (sort compare-items items)))
