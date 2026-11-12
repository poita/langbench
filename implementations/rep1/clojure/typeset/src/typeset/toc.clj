(ns typeset.toc
  "The table of contents: its vertical list, with leaders and page labels."
  (:require [typeset.inline :as inline]
            [typeset.metrics :as m]
            [typeset.text :as text]
            [typeset.util :as u :refer [fdiv]]
            [typeset.vlist :as vl]))

(set! *warn-on-reflection* true)

(defn- plain-chars [^String s]
  (mapv (fn [c] {:k :char :c c :st inline/empty-style}) (u/code-points s)))

(defn- add-leaders
  "Append the leaders and the page label to the last of `lines`."
  [env lines left label]
  (let [settings (:settings env)
        faces (:faces env)
        fname (m/face-name (settings "toc-font") false false)
        face (faces fname)
        size (long (settings "toc-size"))
        gap (long (settings "toc-leader-gap"))
        leader (settings "toc-leader")
        lw (m/string-width face label size)
        label-x (- (+ (long (:body-x settings)) (long (:body-width settings))) lw)
        last-line (peek lines)
        x-from (+ (long (:x-end last-line)) gap)
        x-to (- label-x gap)
        unit (m/string-width face leader size)
        k (max 0 (u/fdiv (- x-to x-from) unit))
        run (fn [t x w] {:text t :face fname :size size :raise 0 :x x :w w})
        runs (cond-> (:runs last-line)
               (pos? k) (conj (run (apply str (repeat k leader)) (- x-to (* k unit)) (* k unit)))
               true (conj (run label label-x lw)))]
    (conj (pop lines) (assoc last-line :runs runs))))

(defn build
  "The vertical items of the table of contents. `title` is the title text,
  `entries` a seq of `{:level :number :text :label}`."
  [env title entries]
  (let [settings (:settings env)
        vl* (vl/create)
        bx (long (:body-x settings))
        bw (long (:body-width settings))
        tctx {:family (settings "toc-title-font") :bold (settings "heading-bold")
              :italic (settings "heading-italic") :size (settings "toc-title-size")
              :leading (settings "h1-leading") :left bx :measure bw
              :align (settings "heading-align") :hyphenate (settings "hyphenate")}]
    (vl/leaf! vl* 0 (settings "toc-title-space-after")
              (fn []
                (let [{:keys [lines]} (text/typeset env tctx (inline/string-units title) 0)]
                  (vl/add-group! vl* lines :other nil nil))))
    (doseq [{:keys [level number text label]} entries]
      (let [indent (* (dec (long level)) (long (settings "toc-indent")))
            ctx {:family (settings "toc-font") :bold false :italic false
                 :size (settings "toc-size") :leading (settings "toc-leading")
                 :left (+ bx indent)
                 :measure (text/clamp-measure (- bw indent (settings "toc-reserve")))
                 :align :left :hyphenate (settings "hyphenate")}
            units (vec (concat (when (seq number)
                                 (concat (plain-chars number)
                                         [{:k :gap :w (settings "toc-number-gap")}]))
                               (inline/string-units text)))
            sp (settings "toc-entry-space")]
        (vl/leaf! vl* sp sp
                  (fn []
                    (let [{:keys [lines]} (text/typeset env ctx units 0)
                          lines (add-leaders env lines (:left ctx) label)]
                      (vl/add-group! vl* lines :other nil nil))))))
    (vl/items vl*)))
