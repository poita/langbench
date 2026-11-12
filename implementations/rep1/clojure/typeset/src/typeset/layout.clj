(ns typeset.layout
  "Walking the block tree: contexts, space between blocks, headings, lists,
  quotes, preformatted text, tables and figures. Produces the body's vertical
  item list."
  (:require [clojure.string :as str]
            [typeset.hlist :as hlist]
            [typeset.inline :as inline]
            [typeset.line :as line]
            [typeset.metrics :as m]
            [typeset.table :as table]
            [typeset.text :as text]
            [typeset.util :as u :refer [fdiv]]
            [typeset.vlist :as vl]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Contexts

(defn root-context
  "The root horizontal-list context for the document body."
  [settings]
  {:family (settings "body-font") :bold false :italic false
   :size (settings "body-size") :leading (settings "leading")
   :left (:body-x settings) :measure (:body-width settings)
   :align (settings "align") :hyphenate (settings "hyphenate")
   :list-depth 0})

(defn footnote-context [settings]
  {:family (settings "footnote-font") :bold false :italic false
   :size (settings "footnote-size") :leading (settings "footnote-leading")
   :left (+ (:body-x settings) (settings "footnote-indent"))
   :measure (text/clamp-measure (- (:body-width settings) (settings "footnote-indent")))
   :align (settings "align") :hyphenate (settings "hyphenate")})

(defn- indent-ctx [ctx left-by measure-by]
  (-> ctx
      (update :left + left-by)
      (update :measure #(text/clamp-measure (- % measure-by)))))

;; ---------------------------------------------------------------------------
;; Figures

(defn layout-figure
  "Lay out a figure block relative to its top: returns `{:height :fx :fw :frame?
  :lines [{:dy :runs}]}`. The caption is typeset once, here."
  [env {:keys [index height width units]}]
  (let [settings (:settings env)
        w (or width (settings "figure-width"))
        fw (if (pos? w) w (:body-width settings))
        fx (+ (:body-x settings) (fdiv (- (:body-width settings) fw) 2))
        prefix (settings "figure-caption-prefix")
        ctx {:family (settings "figure-caption-font") :bold false :italic false
             :size (settings "figure-caption-size") :leading (settings "figure-caption-leading")
             :left fx :measure (text/clamp-measure fw)
             :align (settings "figure-caption-align") :hyphenate (settings "hyphenate")}
        cap-units (vec (concat (when (seq prefix)
                                 (concat (inline/string-units prefix)
                                         [{:k :space :st inline/empty-style :plain true}]))
                               (inline/string-units (str index "."))
                               [{:k :gap :w (settings "figure-caption-gap")}]
                               units))
        {:keys [lines]} (text/typeset env ctx cap-units 0)
        top (+ height (settings "figure-caption-space"))
        {:keys [baselines end]} (vl/stack-lines lines top (settings "line-skip"))]
    {:index index :height end :fx fx :fw fw :frame? (settings "figure-frame")
     :frame-height height
     :lines (mapv (fn [ln bl] {:dy bl :runs (:runs ln)}) lines baselines)}))

;; ---------------------------------------------------------------------------
;; Headings

(defn- number-string [counters level]
  (str/join "." (take level counters)))

;; ---------------------------------------------------------------------------
;; Markers

(defn- marker-text [list-type depth n]
  (case (long (mod depth 3))
    1 (if (= list-type :ul) "•" (str n "."))
    2 (if (= list-type :ul) "–" (str (u/letters n) "."))
    0 (if (= list-type :ul) "*" (str (u/roman n) "."))))

;; ---------------------------------------------------------------------------
;; The walk

(declare walk-blocks)

(defn- plain-chars [^String s]
  (mapv (fn [c] {:k :char :c c :st inline/empty-style}) (u/code-points s)))

(defn- walk-heading [env vl ctx blk]
  (let [settings (:settings env)
        level (:level blk)
        numbered? (and (:numbered? blk) (settings "heading-number"))
        counters (:counters env)
        num (when numbered?
              (swap! counters (fn [c] (vec (concat (take (dec level) c)
                                                   [(inc (nth c (dec level)))]
                                                   (repeat (- 4 level) 0)))))
              (number-string @counters level))
        hid (count @(:headings env))
        hctx {:family (settings "heading-font") :bold (settings "heading-bold")
              :italic (settings "heading-italic")
              :size (settings (str "h" level "-size"))
              :leading (settings (str "h" level "-leading"))
              :left (:left ctx) :measure (:measure ctx)
              :align (settings "heading-align") :hyphenate (:hyphenate ctx)}
        units (vec (concat (when numbered?
                             (concat (plain-chars num)
                                     [{:k :gap :w (settings "heading-number-gap")}]))
                           (:units blk)))]
    (swap! (:headings env) conj {:level level :number (or num "") :star? (boolean (not (:numbered? blk)))
                                 :text (inline/plain-text (:units blk))
                                 :numbered? (boolean numbered?)})
    (text/bump! env :headings)
    (when (and (== level 1) (settings "h1-newpage"))
      (vl/add! vl {:t :forcebreak})
      (vl/reset-registers! vl)
      (vl/mark-started! vl))
    (vl/leaf! vl (settings (str "h" level "-space-before")) (settings (str "h" level "-space-after"))
              (fn []
                (let [{:keys [lines]} (text/typeset env hctx units 0)]
                  (vl/add-group! vl lines :heading {:hid hid} nil))))))

(defn- walk-paragraph [env vl ctx blk]
  (let [settings (:settings env)
        sp (settings "par-space")]
    (vl/leaf! vl sp sp
              (fn []
                (text/bump! env :paragraphs)
                (let [{:keys [lines]} (text/typeset env ctx (:units blk) (settings "par-indent"))]
                  (vl/add-group! vl lines :other nil nil))))))

(defn- walk-pre [env vl ctx blk]
  (let [settings (:settings env)
        faces (:faces env)
        sp (settings "pre-space")
        pctx (-> ctx
                 (assoc :family (settings "pre-font") :bold false :italic false
                        :size (settings "pre-size") :leading (settings "pre-leading")
                        :align :left)
                 (indent-ctx (settings "pre-indent") (settings "pre-indent")))
        face (faces (m/face-name (:family pctx) false false))
        size (long (:size pctx))
        [ctx-a ctx-d] (line/context-metrics faces pctx)]
    (vl/leaf! vl sp sp
              (fn []
                (let [lines (mapv (fn [^String s]
                                    (if (empty? s)
                                      {:runs [] :ascent ctx-a :depth ctx-d :leading (:leading pctx)
                                       :notes [] :overfull? false}
                                      (let [cps (u/code-points s)
                                            w (m/box-width face cps 0 (alength cps) size)]
                                        {:runs [{:text s :face (m/face-name (:family pctx) false false)
                                                 :size size :raise 0 :x (:left pctx) :w w}]
                                         :ascent (m/ascent face size) :depth (m/descent face size)
                                         :leading (:leading pctx) :notes []
                                         :overfull? (> w (:measure pctx))})))
                                  (:lines blk))]
                  (text/record-lines! env lines)
                  (vl/add-group! vl lines :other nil nil))))))

(defn- walk-list [env vl ctx blk]
  (let [settings (:settings env)
        depth (inc (:list-depth ctx))
        li (settings "list-indent")
        ctx' (-> ctx (indent-ctx li li) (assoc :list-depth depth))
        faces (:faces env)
        ls (settings "list-space")]
    (vl/pmax! vl ls)
    (doseq [[idx item] (map-indexed vector (:items blk))]
      (when (pos? idx) (vl/pmax! vl (settings "list-item-space")))
      (vl/leaf! vl 0 0
                (fn []
                  (let [{:keys [lines]} (text/typeset env ctx' (:units item) 0)
                        mtext (marker-text (:type blk) depth
                                           (+ (if (= :ol (:type blk)) (:start blk) 1) idx))
                        face-name (m/face-name (:family ctx') false false)
                        size (long (:size ctx'))
                        w (m/string-width (faces face-name) mtext size)
                        marker {:text mtext :face face-name :size size :raise 0
                                :x (- (:left ctx') (settings "list-marker-gap") w) :w w}]
                    (vl/add-group! vl lines :other nil {:marker marker}))))
      (walk-blocks env vl ctx' (:children item)))
    (vl/pmax! vl ls)))

(defn- walk-block [env vl ctx blk]
  (let [settings (:settings env)]
    (case (:type blk)
      :paragraph (walk-paragraph env vl ctx blk)
      :heading (walk-heading env vl ctx blk)
      :q (let [qi (settings "quote-indent") qs (settings "quote-space")]
           (vl/pmax! vl qs)
           (walk-blocks env vl (indent-ctx ctx qi (* 2 qi)) (:children blk))
           (vl/pmax! vl qs))
      :block (let [{:strs [align indent right-indent font size leading]} (:attrs blk)
                   ctx' (cond-> ctx
                          align (assoc :align align)
                          size (assoc :size size)
                          leading (assoc :leading leading)
                          font (assoc :family font))
                   ctx' (indent-ctx ctx' (or indent 0) (+ (or indent 0) (or right-indent 0)))]
               (walk-blocks env vl ctx' (:children blk)))
      (:ul :ol) (walk-list env vl ctx blk)
      :table (let [sp (settings "table-space")]
               (vl/leaf! vl sp sp
                         (fn []
                           (text/bump! env :tables)
                           (doseq [it (table/layout env ctx blk)] (vl/add! vl it)))))
      :pre (walk-pre env vl ctx blk)
      :fig (do (text/bump! env :figures)
               (swap! (:figures env) assoc (:index blk) (layout-figure env blk))
               (vl/leaf! vl 0 0 (fn [] (vl/add! vl {:t :floatmark :index (:index blk)}))))
      :rule (let [sp (settings "rule-space")]
              (vl/leaf! vl sp sp
                        (fn [] (vl/add! vl {:t :rule :x (:left ctx) :w (:measure ctx)
                                            :thick (settings "rule-thickness")}))))
      :vspace (vl/padd! vl (:height blk))
      :newpage (do (vl/add! vl {:t :forcebreak})
                   (vl/reset-registers! vl)
                   (vl/mark-started! vl)))))

(defn walk-blocks [env vl ctx blocks]
  (doseq [b blocks] (walk-block env vl ctx b)))

(defn layout-body
  "Walk the document's blocks; returns the vertical items."
  [env blocks]
  (let [vl (vl/create)]
    (walk-blocks env vl (root-context (:settings env)) blocks)
    (vl/items vl)))
