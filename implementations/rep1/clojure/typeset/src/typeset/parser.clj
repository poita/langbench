(ns typeset.parser
  "The Codexa document parser. Produces a block tree whose inline text has
  been scanned into units (see `typeset.inline`) and reports the first error
  in the order fixed by the specification.

  Block nodes are maps with a `:type`:

    {:type :paragraph :units u}
    {:type :heading :level n :numbered? b :units u}
    {:type :q :children bs}
    {:type :block :attrs {...} :children bs}
    {:type :ul|:ol :start n :items [{:units u :children bs}]}
    {:type :table :cols n :aligns [\\l ...] :elements [{:row [units...]} | :hrule]}
    {:type :pre :lines [string]}
    {:type :fig :index n :height h :width w :units u}
    {:type :rule} {:type :vspace :height h} {:type :newpage}

  The result of `parse` is `{:meta {...} :toc nil|{:title s} :blocks bs
  :footnotes n :figures n}`."
  (:require [clojure.string :as str]
            [typeset.inline :as inline]
            [typeset.settings :as settings]
            [typeset.util :as u :refer [fail]]))

(set! *warn-on-reflection* true)

(def ^:private file "document.cdx")

;; ---------------------------------------------------------------------------
;; Attribute specifications

(def ^:private specs
  {"@doc" {}
   "@toc" {"title" :text}
   "@q" {}
   "@block" {"align" :align "indent" :len0 "right-indent" :len0
             "font" :font "size" :size "leading" :leading}
   "@ul" {}
   "@ol" {"start" :start}
   "@table" {"cols" :cols "align" :talign}
   "@hrule" {}
   "@pre" {}
   "@fig" {"height" :len0 "width" :len0}
   "@rule" {}
   "@vspace" {"height" :len0}
   "@newpage" {}
   "@end" {}})

(def ^:private required
  {"@table" ["cols"] "@fig" ["height"] "@vspace" ["height"]})

(def ^:private heading-names #{"@h1" "@h2" "@h3" "@h4" "@h1*" "@h2*" "@h3*" "@h4*"})

(defn- check-value
  "Interpret attribute value text `s` of type `t`; `::bad` when invalid."
  [t ^String s]
  (let [len (fn [lo hi] (let [v (settings/parse-length s)]
                          (if (and v (>= v lo) (or (nil? hi) (<= v hi))) v ::bad)))
        int* (fn [lo hi] (let [v (settings/parse-integer s)]
                           (if (and v (<= lo v hi)) v ::bad)))]
    (case t
      :align (if (#{"justify" "left" "right" "center"} s) (keyword s) ::bad)
      :font (if (#{"serif" "sans" "mono"} s) s ::bad)
      :len0 (len 0 nil)
      :size (len 1000 200000)
      :leading (len 1000 nil)
      :start (int* 1 100000)
      :cols (int* 1 20)
      :talign (if (and (seq s) (every? #{\l \r \c} s)) s ::bad)
      :text s)))

;; ---------------------------------------------------------------------------
;; Line helpers

(defn- first-nonspace ^long [^ints cps]
  (let [n (alength cps)]
    (loop [i 0] (if (and (< i n) (== 32 (aget cps i))) (recur (inc i)) i))))

(defn- name-char? [^long c]
  (or (<= 65 c 90) (<= 97 c 122) (<= 48 c 57) (== c 45)))

(defn- bare-char? [^long c]
  (or (name-char? c) (== c 46) (== c 43) (== c 37)))

(defn- lex-attrs
  "Lexically read the attribute tokens of a directive line from index `p`.
  Returns a vector of `{:name :text :vcol}` (column of the value start)."
  [^ints cps p allowed ln]
  (let [n (alength cps)
        bad-attr (fn [i] (fail file ln (inc i) "bad-attribute"))
        bad-val (fn [i] (fail file ln (inc i) "bad-attribute-value"))]
    (loop [p (long p) out []]
      (let [p (long (loop [p p] (if (and (< p n) (== 32 (aget cps p))) (recur (inc p)) p)))]
        (if (>= p n)
          out
          (let [q (long (loop [q p] (if (and (< q n) (name-char? (aget cps q))) (recur (inc q)) q)))]
            (when (or (== q p) (>= q n) (not= 61 (aget cps q))) (bad-attr p))
            (let [nm (u/cps->str cps p q)]
              (when (or (not (contains? allowed nm)) (some #(= nm (:name %)) out)) (bad-attr p))
              (let [v (inc q)]
                (if (and (< v n) (== 34 (aget cps v)))
                  (let [j (long (loop [j (inc v)] (if (and (< j n) (not= 34 (aget cps j))) (recur (inc j)) j)))]
                    (when (>= j n) (bad-val v))
                    (let [after (inc j)]
                      (when (and (< after n) (not= 32 (aget cps after))) (bad-val v))
                      (recur after (conj out {:name nm :text (u/cps->str cps (inc v) j)
                                              :vcol (inc v)}))))
                  (let [j (long (loop [j v] (if (and (< j n) (bare-char? (aget cps j))) (recur (inc j)) j)))]
                    (when (== j v) (bad-val v))
                    (when (and (< j n) (not= 32 (aget cps j))) (bad-val v))
                    (recur j (conj out {:name nm :text (u/cps->str cps v j) :vcol (inc v)}))))))))))))

(defn- line-arrays
  "Source line and column arrays for a single line of `n` code points."
  [ln n]
  (let [lns (int-array n (int ln))
        cols (int-array n)]
    (dotimes [i n] (aset cols i (int (inc i))))
    [lns cols]))

(defn- join-pieces
  "Join text pieces `{:ln :cps :from}` with single spaces; returns
  `[cps lns cols]`."
  [pieces]
  (let [cps (java.util.ArrayList.) lns (java.util.ArrayList.) cols (java.util.ArrayList.)]
    (doseq [[idx {:keys [ln ^ints cps-line from]}] (map-indexed vector pieces)]
      (when (pos? idx)
        (.add cps (int 32)) (.add lns (int ln)) (.add cols (int 1)))
      (loop [i (long from)]
        (when (< i (alength cps-line))
          (.add cps (aget cps-line i)) (.add lns (int ln)) (.add cols (int (inc i)))
          (recur (inc i)))))
    [(int-array cps) (int-array lns) (int-array cols)]))

;; ---------------------------------------------------------------------------
;; The parser

(def ^:private container-kinds #{:root :q :block :li})

(defn parse
  "Parse the text of `document.cdx`."
  [text]
  (let [lines (let [ls (str/split text #"\n" -1)]
                (if (and (seq ls) (= "" (peek ls))) (pop ls) ls))
        nlines (count lines)
        stack (volatile! [{:kind :root :children []}])
        pend (volatile! nil)
        root-kinds (volatile! [])
        toc (volatile! nil)
        meta* (volatile! {})
        notes (volatile! 0)
        figs (volatile! 0)
        next-note! (fn [] (vswap! notes inc))
        top (fn [] (peek @stack))
        depth (fn [] (count @stack))
        scan-opts {:file file :next-note! next-note!}
        update-top! (fn [f & args] (vswap! stack (fn [s] (conj (pop s) (apply f (peek s) args)))))
        add-child! (fn [node] (update-top! update :children conj node))
        note-root! (fn [kind] (when (== 1 (depth)) (vswap! root-kinds conj kind)))
        scan-pieces (fn [pieces opts]
                      (let [[cps lns cols] (join-pieces pieces)]
                        (inline/scan cps lns cols 0 (alength ^ints cps) opts)))
        finish-pending!
        (fn []
          (when-let [{:keys [pieces target]} @pend]
            (vreset! pend nil)
            (let [units (scan-pieces pieces scan-opts)]
              (case target
                :paragraph (add-child! {:type :paragraph :units units})
                :li (update-top! assoc :units units)))))
        close-frame!
        (fn []
          (let [{:keys [kind] :as f} (top)]
            (vswap! stack pop)
            (case kind
              :li (update-top! update :items conj {:units (or (:units f) []) :children (:children f)})
              :q (add-child! {:type :q :children (:children f)})
              :block (add-child! {:type :block :attrs (:attrs f) :children (:children f)})
              (:ul :ol) (add-child! {:type kind :start (:start f) :items (:items f)})
              :table (add-child! {:type :table :cols (:cols f) :aligns (:aligns f)
                                  :elements (:elements f)})
              :pre (add-child! {:type :pre :lines (:lines f)})
              :fig (let [units (scan-pieces (:pieces f) (assoc scan-opts :no-notes? true))]
                     (add-child! {:type :fig :index (:index f) :height (:height f)
                                  :width (:width f) :units units}))
              :doc nil)))]
    (doseq [[idx line] (map-indexed vector lines)]
      (let [ln (inc idx)
            ^ints cps (u/code-points ^String line)
            n (alength cps)
            fnb (first-nonspace cps)
            blank? (== fnb n)
            directive? (and (not blank?) (== 64 (aget cps fnb)))
            kind (:kind (top))]
        (cond
          ;; ---- raw @pre content
          (= kind :pre)
          (if (= "@end" (str/trim line))
            (close-frame!)
            (update-top! update :lines conj (str/replace line #" +$" "")))

          blank? (finish-pending!)

          ;; ---- text lines
          (not directive?)
          (case kind
            :doc
            (let [a (settings/split-assignment cps)]
              (when-not a (fail file ln (inc fnb) "bad-syntax"))
              (let [kk (:key a)]
                (when-not (#{"title" "author" "date"} kk) (fail file ln (inc (:key-col a)) "unknown-meta"))
                (when (contains? @meta* kk) (fail file ln (inc (:key-col a)) "duplicate-meta"))
                (vswap! meta* assoc kk (u/cps->str cps (:value-start a) (:value-end a)))))
            :table
            (let [{:keys [cols]} (top)
                  ;; split into cells before parsing any inline content
                  bounds (loop [i fnb s fnb out []]
                           (cond (>= i n) (conj out [s n])
                                 (== 92 (aget cps i)) (recur (+ i 2) s out)
                                 (== 124 (aget cps i)) (recur (inc i) (inc i) (conj out [s i]))
                                 :else (recur (inc i) s out)))
                  bounds (mapv (fn [[s e]] [s (min e n)]) bounds)]
              (when (not= cols (count bounds)) (fail file ln 1 "cell-count"))
              (let [[lns cl] (line-arrays ln n)
                    row (mapv (fn [[s e]] (inline/scan cps lns cl s e scan-opts)) bounds)]
                (update-top! update :elements conj {:row row})))
            :fig
            (update-top! update :pieces conj {:ln ln :cps-line cps :from fnb})
            (:ul :ol)
            (fail file ln (inc fnb) "text-not-allowed")
            ;; root, q, block, li
            (if @pend
              (vswap! pend update :pieces conj {:ln ln :cps-line cps :from fnb})
              (do (note-root! :other)
                  (vreset! pend {:target :paragraph
                                 :pieces [{:ln ln :cps-line cps :from fnb}]}))))

          ;; ---- directives
          :else
          (do
            (finish-pending!)
            (let [kind (:kind (top))
                  name-end (loop [i fnb] (if (and (< i n) (not= 32 (aget cps i))) (recur (inc i)) i))
                  dname (u/cps->str cps fnb name-end)
                  at-col (inc fnb)
                  not-allowed (fn [] (fail file ln at-col "block-not-allowed"))
                  after-name (loop [i name-end] (if (and (< i n) (== 32 (aget cps i))) (recur (inc i)) i))]
              (cond
                (not (or (contains? specs dname) (contains? heading-names dname) (= dname "@li")))
                (fail file ln at-col "unknown-block")

                ;; ---- headings
                (contains? heading-names dname)
                (do
                  (when-not (container-kinds kind) (not-allowed))
                  (note-root! :other)
                  (let [[lns cl] (line-arrays ln n)
                        units (inline/scan cps lns cl after-name n (assoc scan-opts :no-notes? true))]
                    (add-child! {:type :heading :level (- (int (.charAt ^String dname 2)) 48)
                                 :numbered? (not (str/ends-with? dname "*")) :units units})))

                ;; ---- list items
                (= dname "@li")
                (cond
                  (#{:ul :ol} kind)
                  (do (vswap! stack conj {:kind :li :children []})
                      (vreset! pend {:target :li :pieces [{:ln ln :cps-line cps :from after-name}]}))
                  (and (= kind :li) (#{:ul :ol} (:kind (peek (pop @stack)))))
                  (do (close-frame!)
                      (vswap! stack conj {:kind :li :children []})
                      (vreset! pend {:target :li :pieces [{:ln ln :cps-line cps :from after-name}]}))
                  :else (not-allowed))

                :else
                (let [spec (specs dname)
                      attrs (lex-attrs cps name-end spec ln)
                      attr-map (into {} (map (juxt :name identity)) attrs)]
                  (doseq [r (required dname)]
                    (when-not (contains? attr-map r) (fail file ln at-col "missing-attribute")))
                  ;; placement
                  (case dname
                    "@end" (when (== 1 (depth)) (fail file ln at-col "unexpected-end"))
                    "@hrule" (when-not (= kind :table) (not-allowed))
                    "@doc" (when-not (and (== 1 (depth)) (empty? @root-kinds)) (not-allowed))
                    "@toc" (if @toc
                             (if (#{:ul :ol :table :doc :fig} kind)
                               (not-allowed)
                               (fail file ln at-col "duplicate-toc"))
                             (when-not (and (== 1 (depth)) (#{[] [:doc]} @root-kinds))
                               (not-allowed)))
                    (when-not (container-kinds kind) (not-allowed)))
                  ;; values
                  (let [av (reduce
                              (fn [m {:keys [name text vcol]}]
                                (let [v (check-value (spec name) text)]
                                  (when (= v ::bad) (fail file ln vcol "bad-attribute-value"))
                                  (assoc m name v)))
                              {} attrs)]
                    (when (= dname "@table")
                      (let [cols (av "cols")
                            al (av "align")]
                        (when (and al (not= (count al) cols))
                          (fail file ln (:vcol (attr-map "align")) "bad-attribute-value"))))
                    (case dname
                      "@end" (do (when (= :li kind) (close-frame!))
                                 (close-frame!))
                      "@doc" (do (note-root! :doc) (vswap! stack conj {:kind :doc}))
                      "@toc" (do (note-root! :toc)
                                 (vreset! toc {:title (av "title")}))
                      "@q" (do (note-root! :other) (vswap! stack conj {:kind :q :children []}))
                      "@block" (do (note-root! :other)
                                   (vswap! stack conj {:kind :block :attrs av :children []}))
                      "@ul" (do (note-root! :other) (vswap! stack conj {:kind :ul :items []}))
                      "@ol" (do (note-root! :other)
                                (vswap! stack conj {:kind :ol :start (get av "start" 1) :items []}))
                      "@table" (let [cols (av "cols")]
                                 (note-root! :other)
                                 (vswap! stack conj
                                         {:kind :table :cols cols :elements []
                                          :aligns (vec (or (av "align") (apply str (repeat cols "l"))))}))
                      "@hrule" (update-top! update :elements conj :hrule)
                      "@pre" (do (note-root! :other) (vswap! stack conj {:kind :pre :lines []}))
                      "@fig" (do (note-root! :other)
                                 (vswap! stack conj {:kind :fig :index (vswap! figs inc)
                                                     :height (av "height") :width (av "width")
                                                     :pieces []}))
                      "@rule" (do (note-root! :other) (add-child! {:type :rule}))
                      "@vspace" (do (note-root! :other)
                                    (add-child! {:type :vspace :height (av "height")}))
                      "@newpage" (do (note-root! :other) (add-child! {:type :newpage}))))))))))
      nil)
    (finish-pending!)
    (when (> (depth) 1) (fail file (inc nlines) 1 "missing-end"))
    {:meta (merge {"title" "" "author" "" "date" ""} @meta*)
     :toc @toc
     :blocks (:children (top))
     :footnotes @notes
     :figures @figs}))
