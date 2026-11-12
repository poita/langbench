(ns textbuffer.properties-test
  "Generative tests: the buffer is compared against a deliberately naive model
  of the editing rules (a single string, cursors as character offsets, every
  later cursor rewritten after every replacement), and against structural
  invariants and the undo/redo laws."
  (:require [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [textbuffer.buffer :as b]
            [textbuffer.document :as doc]
            [textbuffer.position :as p]))

;; ---------------------------------------------------------------------------
;; Generators

(def gen-line (gen/fmap #(apply str %) (gen/vector (gen/elements [\a \b \c \space \~]) 0 6)))

(def gen-lines (gen/vector gen-line 1 6))

(def gen-text
  (gen/fmap #(apply str %) (gen/vector (gen/elements [\x \y \space \newline]) 1 5)))

(def gen-coord (gen/one-of [(gen/choose 0 8) (gen/return 1000000000)]))

(def gen-op
  (gen/frequency
   [[4 (gen/fmap (fn [t] [:insert t]) gen-text)]
    [3 (gen/return [:delete])]
    [3 (gen/return [:delete-forward])]
    [6 (gen/fmap (fn [[d s]] [:move d s])
                 (gen/tuple (gen/elements [:left :right :up :down :home :end]) gen/boolean))]
    [2 (gen/fmap (fn [[l c]] [:goto l c]) (gen/tuple gen-coord gen-coord))]
    [4 (gen/fmap (fn [[l c]] [:add-cursor l c]) (gen/tuple gen-coord gen-coord))]
    [1 (gen/return [:clear-cursors])]
    [3 (gen/return [:undo])]
    [2 (gen/return [:redo])]]))

(def gen-scenario (gen/tuple gen-lines (gen/vector gen-op 0 40)))

(defn- apply-op [buf [op a1 a2]]
  (case op
    :insert (b/insert buf a1)
    :delete (b/delete-backward buf)
    :delete-forward (b/delete-forward buf)
    :move (b/move buf a1 a2)
    :goto (b/goto buf a1 a2)
    :add-cursor (b/add-cursor buf a1 a2)
    :clear-cursors (b/clear-cursors buf)
    :undo (b/undo buf)
    :redo (b/redo buf)))

;; ---------------------------------------------------------------------------
;; Naive model of edit commands (offsets in one string)

(defn- offset [lines p]
  (+ (p/col p) (reduce + (map #(inc (count %)) (take (p/line p) lines)))))

(defn- model-edit
  "Returns `[text head-offsets]` after applying `kind` to the buffer's current
  state with the naive offset-based algorithm."
  [buf kind ins]
  (let [lines (b/lines buf)
        text0 (apply str (interpose "\n" lines))
        curs (mapv (fn [c]
                     (let [h (offset lines (:head c))
                           a (some-> (:anchor c) (->> (offset lines)))]
                       {:s (if a (min h a) h) :e (if a (max h a) h) :sel? (some? a)}))
                   (b/cursors buf))]
    (loop [i 0 text text0 curs curs heads []]
      (if (== i (count curs))
        [text heads]
        (let [{:keys [s e sel?]} (nth curs i)
              [rs re] (cond sel? [s e]
                            (= kind :insert) [s s]
                            (= kind :delete) (if (zero? s) [s s] [(dec s) s])
                            :else (if (== s (count text)) [s s] [s (inc s)]))
              m (count ins)
              text' (str (subs text 0 rs) ins (subs text re))
              shift #(if (>= % re) (+ (- % re) rs m) %)
              curs' (vec (concat (subvec curs 0 (inc i))
                                 (map (fn [c] (-> c (update :s shift) (update :e shift)))
                                      (subvec curs (inc i)))))]
          (recur (inc i) text' curs' (conj heads (+ rs m))))))))

(defn- model-matches-edit? [buf kind arg]
  (let [[mtext heads] (model-edit buf kind (if (= kind :insert) arg ""))
        buf' (case kind
               :insert (b/insert buf arg)
               :delete (b/delete-backward buf)
               :delete-forward (b/delete-forward buf))
        lines' (b/lines buf')
        actual-heads (mapv #(offset lines' (:head %)) (b/cursors buf'))]
    (and (= mtext (apply str (interpose "\n" lines')))
         (= (vec (distinct (sort heads))) actual-heads))))

(defspec edits-match-naive-model 300
  (prop/for-all [[lines ops] gen-scenario
                 kind (gen/elements [:insert :delete :delete-forward])
                 text gen-text]
    (let [buf (reduce apply-op (b/from-lines lines) ops)]
      (model-matches-edit? buf kind text))))

;; ---------------------------------------------------------------------------
;; Invariants

(defn- valid? [buf]
  (let [d (:doc buf)
        cs (b/cursors buf)
        in-doc? (fn [pos]
                  (let [l (p/line pos)]
                    (and (< l (doc/line-count d)) (<= (p/col pos) (doc/line-length d l)))))
        starts (map (fn [c] (min (:head c) (or (:anchor c) (:head c)))) cs)]
    (and (seq cs)
         (== 1 (count (filter :primary cs)))
         (every? #(in-doc? (:head %)) cs)
         (every? #(or (nil? (:anchor %)) (and (in-doc? (:anchor %)) (not= (:anchor %) (:head %)))) cs)
         (apply < -1 starts)
         (every? #(not (re-find #"\n" %)) (b/lines buf)))))

(defspec invariants-hold-after-every-command 300
  (prop/for-all [[lines ops] gen-scenario]
    (->> (reductions apply-op (b/from-lines lines) ops)
         (every? valid?))))

(defspec goal-column-equals-head-column-after-non-vertical-commands 200
  (prop/for-all [[lines ops] gen-scenario]
    (let [bufs (reductions apply-op (b/from-lines lines) ops)]
      (every? (fn [[buf [op dir]]]
                (or (and (= op :move) (#{:up :down} dir))
                    (every? #(== (:goal %) (p/col (:head %))) (b/cursors buf))))
              (map vector (rest bufs) ops)))))

;; ---------------------------------------------------------------------------
;; Undo / redo laws

(declare undo-all redo-all)

(defspec undoing-everything-restores-the-document 300
  (prop/for-all [[lines ops] gen-scenario]
    (let [buf (reduce apply-op (b/from-lines lines) (remove #{[:undo] [:redo]} ops))]
      (= lines (b/lines (undo-all buf))))))

(defn- undo-all [buf]
  (last (take-while some? (iterate #(when (b/can-undo? %) (b/undo %)) buf))))

(defn- redo-all [buf]
  (last (take-while some? (iterate #(when (b/can-redo? %) (b/redo %)) buf))))

(defspec redoing-everything-restores-the-final-document 300
  (prop/for-all [[lines ops] gen-scenario]
    (let [buf (reduce apply-op (b/from-lines lines) (remove #{[:undo] [:redo]} ops))]
      (= (b/lines buf) (b/lines (redo-all (undo-all buf)))))))

(defspec undo-then-redo-restores-document-and-cursors-of-an-edit 300
  (prop/for-all [[lines ops] gen-scenario
                 edit (gen/elements [[:insert "q\nr"] [:delete] [:delete-forward]])]
    (let [before (reduce apply-op (b/from-lines lines) ops)
          buf (apply-op before edit)]
      (or (= (count (:undo buf)) (count (:undo before))) ; the edit changed nothing
          (let [u (b/undo buf)]
            (and (= (b/lines before) (b/lines u))
                 (= (map #(dissoc % :goal) (b/cursors before))
                    (map #(dissoc % :goal) (b/cursors u)))
                 (= (b/lines buf) (b/lines (b/redo u)))
                 (= (b/cursors buf) (b/cursors (b/redo u)))))))))
