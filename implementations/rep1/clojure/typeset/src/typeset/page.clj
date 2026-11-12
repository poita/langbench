(ns typeset.page
  "Running headers and footers."
  (:require [clojure.string :as str]
            [typeset.hlist :as hlist]
            [typeset.inline :as inline]
            [typeset.out :as out]
            [typeset.util :refer [fdiv]]))

(set! *warn-on-reflection* true)

(def ^:private slots
  [[:header "left"] [:header "center"] [:header "right"]
   [:footer "left"] [:footer "center"] [:footer "right"]])

(defn- substitute [segs values]
  (apply str (map #(if (keyword? %) (get values % "") %) segs)))

(defn- slot-items
  "Output items of one slot's text, or nil when nothing remains."
  [env region pos text]
  (let [settings (:settings env)
        faces (:faces env)
        ctx {:family (settings "header-font") :bold false :italic false
             :size (settings "header-size") :align :left :hyphenate false}
        hl (hlist/build env ctx (inline/string-units text))
        n (- (long (:n hl)) 3)
        items (:items hl)
        w-total (loop [i 0 acc 0] (if (< i n) (recur (inc i) (+ acc (long (:w (nth items i))))) acc))]
    (when (pos? n)
      (let [bx (long (:body-x settings)) bw (long (:body-width settings))
            x0 (case pos
                 "left" bx
                 "center" (+ bx (fdiv (- bw w-total) 2))
                 "right" (- (+ bx bw) w-total))
            y (settings (if (= region :header) "header-baseline" "footer-baseline"))]
        (loop [i 0 x x0 outs []]
          (if (< i n)
            (let [it (nth items i)]
              (recur (inc i) (+ x (long (:w it)))
                     (if (:text it)
                       (conj outs (out/text-item region (:face it) (:size it) x y (:w it) (:text it)))
                       outs)))
            outs))))))

(defn render
  "Header and footer items of a page. `info` has `:label`, `:number` (the label
  number deciding odd/even), `:chapter`, `:section` and `:pages`."
  [env {:keys [label number chapter section pages]}]
  (let [settings (:settings env)
        meta* (:meta env)
        values {:page label :pages (str pages) :title (get meta* "title" "")
                :author (get meta* "author" "") :date (get meta* "date" "")
                :chapter (or chapter "") :section (or section "")}]
    (vec (mapcat
          (fn [[region pos]]
            (let [k (str (name region) "-" pos (if (even? number) "-even" ""))
                  text (substitute (settings k) values)]
              (slot-items env region pos text)))
          slots))))
