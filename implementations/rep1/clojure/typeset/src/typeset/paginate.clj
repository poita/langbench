(ns typeset.paginate
  "Page breaking: break legality, the per-page cut scan, floats and footnote
  areas. The same procedure paginates the body and the table of contents."
  (:require [typeset.metrics :as m]
            [typeset.out :as out]
            [typeset.vlist :as vl]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Break legality

(defn legal-breaks
  "A boolean array over positions `0..n`: whether a page may break before item
  `j` (widows, orphans, heading groups and keep-with-next)."
  ^booleans [items settings]
  (let [items (vec items)
        n (count items)
        orphans (long (settings "orphans"))
        widows (long (settings "widows"))
        legal (boolean-array (inc n))
        keep (boolean-array (inc n))]
    (when (settings "keep-with-next")
      (dotimes [e n]
        (let [it (nth items e)]
          (when (and (= :line (:t it)) (= :heading (:kind it))
                     (or (== (inc e) n) (not= (:gid (nth items (inc e))) (:gid it))))
            (let [x (loop [x (inc e)]
                      (if (and (< x n) (#{:glue :floatmark} (:t (nth items x)))) (recur (inc x)) x))]
              (loop [p (inc e)]
                (when (<= p (min x (dec n)))
                  (aset keep p true)
                  (recur (inc p)))))))))
    (dotimes [j (inc n)]
      (aset legal j
            (boolean
             (and (pos? j)
                  (or (== j n)
                      (and (not (aget keep j))
                           (let [it (nth items j)]
                             (if (= :line (:t it))
                               (let [k (long (:k it)) ng (long (:n it))]
                                 (if (= :heading (:kind it))
                                   (== k 1)
                                   (or (== k 1)
                                       (and (>= (dec k) orphans) (>= (inc (- ng k)) widows)))))
                               true))))))))
    legal))

;; ---------------------------------------------------------------------------
;; Footnote stacks

(defn- fn-state-add-group
  "Advance footnote stack state `[cursor fresh pb pd groups]` over group
  `g` (a map with `:lines`)."
  [[cursor fresh pb pd groups] g item-space line-skip]
  (let [[cursor fresh] (if (pos? groups) [(+ cursor item-space) true] [cursor fresh])]
    (loop [ls (seq (:lines g)) cursor cursor fresh fresh pb pb pd pd]
      (if ls
        (let [{:keys [ascent depth leading]} (first ls)
              bl (vl/baseline fresh cursor pb pd ascent leading line-skip)]
          (recur (next ls) (+ bl (long depth)) false bl (long depth)))
        [cursor fresh pb pd (inc groups)]))))

(defn- group-line-heights
  "For the candidate `groups`, a vector with, for every line in order,
  `[group-index index-in-group stack-height-after-line]`."
  [groups item-space line-skip]
  (loop [gs (seq groups) gi 0 cursor 0 fresh true pb 0 pd 0 out []]
    (if gs
      (let [g (first gs)
            [cursor fresh] (if (pos? gi) [(+ cursor item-space) true] [cursor fresh])
            [cursor fresh pb pd out]
            (loop [ls (seq (:lines g)) li 0 cursor cursor fresh fresh pb pb pd pd out out]
              (if ls
                (let [{:keys [ascent depth leading]} (first ls)
                      bl (vl/baseline fresh cursor pb pd ascent leading line-skip)
                      c (+ bl (long depth))]
                  (recur (next ls) (inc li) c false bl (long depth) (conj out [gi li c])))
                [cursor fresh pb pd out]))]
        (recur (next gs) (inc gi) (long cursor) fresh (long pb) (long pd) out))
      out)))

;; ---------------------------------------------------------------------------
;; Placing

(defn- place-body
  "Place items `i`..`end`-1 from `body-top`. Returns `{:out :used :heads
  :marks}`."
  [items i end body-top line-skip]
  (loop [k i cursor body-top fresh true pb 0 pd 0 outs (transient [])
         heads [] marks []]
    (if (< k end)
      (let [it (nth items k)]
        (case (:t it)
          :line
          (let [bl (vl/baseline fresh cursor pb pd (:ascent it) (:leading it) line-skip)
                outs (reduce (fn [o r] (conj! o (out/run-item :body r bl))) outs (:runs it))
                outs (if-let [mk (:marker it)] (conj! outs (out/run-item :body mk bl)) outs)]
            (recur (inc k) (+ bl (long (:depth it))) false bl (long (:depth it)) outs
                   (if (and (:hid it) (== 1 (long (:k it)))) (conj heads (:hid it)) heads)
                   marks))
          :glue (recur (inc k) (+ cursor (long (:h it))) true pb pd outs heads marks)
          :rule (recur (inc k) (+ cursor (long (:thick it))) true pb pd
                       (conj! outs (out/rule-item :body (:x it) cursor (:w it) (:thick it)))
                       heads marks)
          :row (let [outs (reduce (fn [o {:keys [dy runs]}]
                                    (reduce (fn [o r] (conj! o (out/run-item :body r (+ cursor dy)))) o runs))
                                  outs (:lines it))]
                 (recur (inc k) (+ cursor (long (:height it))) true pb pd outs heads marks))
          :floatmark (recur (inc k) cursor fresh pb pd outs heads (conj marks (:index it)))
          :forcebreak (recur (inc k) cursor fresh pb pd outs heads marks)))
      {:out (persistent! outs) :used (- cursor body-top) :heads heads :marks marks})))

(defn- place-footnotes
  "Items of the footnote area for placed `groups` (maps with `:n`, `:lines`,
  `:mark?`), whose stack height is `h`."
  [env groups h]
  (let [settings (:settings env)
        faces (:faces env)
        thick (long (settings "footnote-rule-thickness"))
        after (long (settings "footnote-space-after"))
        rule-top (- (long (:body-bottom settings)) h after thick)
        stack-top (+ rule-top thick after)
        item-space (long (settings "footnote-item-space"))
        line-skip (settings "line-skip")
        fname (m/face-name (settings "footnote-font") false false)
        msize (long (settings "footnote-mark-size"))
        fx (+ (long (:body-x settings)) (long (settings "footnote-indent")))]
    (loop [gs (seq groups) gi 0 cursor stack-top fresh true pb 0 pd 0
           outs [(out/rule-item :footnote (:body-x settings) rule-top
                                (settings "footnote-rule-width") thick)]]
      (if gs
        (let [g (first gs)
              [cursor fresh] (if (pos? gi) [(+ cursor item-space) true] [cursor fresh])
              [cursor fresh pb pd outs]
              (loop [ls (seq (:lines g)) li 0 cursor cursor fresh fresh pb pb pd pd outs outs]
                (if ls
                  (let [ln (first ls)
                        bl (vl/baseline fresh cursor pb pd (:ascent ln) (:leading ln) line-skip)
                        outs (reduce (fn [o r] (conj o (out/run-item :footnote r bl))) outs (:runs ln))
                        outs (if (and (zero? li) (:mark? g))
                               (let [text (str (:n g))
                                     w (m/string-width (faces fname) text msize)]
                                 (conj outs (out/text-item :footnote fname msize
                                                           (- fx (settings "footnote-mark-gap") w)
                                                           (- bl (settings "footnote-mark-raise"))
                                                           w text)))
                               outs)]
                    (recur (next ls) (inc li) (+ bl (long (:depth ln))) false bl (long (:depth ln)) outs))
                  [cursor fresh pb pd outs]))]
          (recur (next gs) (inc gi) (long cursor) fresh (long pb) (long pd) outs))
        outs))))

(defn- place-figures
  "Items of the figures `figs` (layout maps) stacked from `body-y`."
  [env figs]
  (let [settings (:settings env)
        gap (long (settings "float-space-after"))
        x-body (:body-x settings)]
    (loop [fs (seq figs) y (long (:body-y settings)) outs []]
      (if fs
        (let [f (first fs)
              outs (cond-> outs
                     (:frame? f) (conj (out/box-item :float (:fx f) y (:fw f) (:frame-height f))))
              outs (reduce (fn [o {:keys [dy runs]}]
                             (reduce (fn [o r] (conj o (out/run-item :float r (+ y dy)))) o runs))
                           outs (:lines f))]
          (recur (next fs) (+ y (long (:height f)) gap) outs))
        outs))))

;; ---------------------------------------------------------------------------
;; The page loop

(defn- take-figures
  "Figures taken from the front of `queue` for a page; returns `k`."
  [queue figures settings body-material?]
  (let [gap (long (settings "float-space-after"))
        min-body (long (settings "float-min-body"))
        bh (long (:body-height settings))]
    (loop [k 0 zone 0]
      (if (< k (count queue))
        (let [h (long (:height (figures (nth queue k))))
              z' (+ zone h gap)
              ok? (if body-material?
                    (>= (- bh z') min-body)
                    (or (zero? k) (<= z' bh)))]
          (if ok? (recur (inc k) z') k))
        k))))

(defn paginate
  "Paginate vertical `items`. `figures` maps figure index to its layout and
  `notes` maps footnote number to `{:n :lines}` (both may be empty).
  Returns `{:pages [{:out [...] :heads [hid...]}] :split-lines n}`."
  [env items figures notes]
  (let [settings (:settings env)
        items (vec items)
        n (count items)
        legal (legal-breaks items settings)
        body-y (long (:body-y settings))
        bh (long (:body-height settings))
        line-skip (long (settings "line-skip"))
        item-space (long (settings "footnote-item-space"))
        fn-before (long (settings "footnote-space-before"))
        fn-thick (long (settings "footnote-rule-thickness"))
        fn-after (long (settings "footnote-space-after"))
        fn-fixed (+ fn-before fn-thick fn-after)
        max-h (long (settings "footnote-max-height"))
        min-split (long (settings "footnote-min-split"))
        gap (long (settings "float-space-after"))
        skip-glue (fn [i] (loop [i i] (if (and (< i n) (#{:glue :forcebreak} (:t (nth items i)))) (recur (inc i)) i)))]
    (loop [i 0 queue [] carried [] pages [] split 0]
      (let [i (long (skip-glue i))]
        (if (and (== i n) (empty? queue) (empty? carried))
          {:pages pages :split-lines split}
          (let [body? (< i n)
                k (take-figures queue figures settings body?)
                taken (mapv figures (subvec queue 0 k))
                zone (reduce + 0 (map #(+ (long (:height %)) gap) taken))
                body-top (+ body-y zone)
                goal (- bh zone)
                queue' (subvec queue k)
                ;; ---- step 2: choose the cut
                cut
                (if (< i n)
                  (let [fs0 (reduce (fn [st g] (fn-state-add-group st g item-space line-skip))
                                    [0 true 0 0 0] carried)]
                    (loop [j (inc i) cursor body-top fresh true pb 0 pd 0 last-cursor body-top
                           fs fs0 seen-notes #{} best -1]
                      (let [it (nth items (dec j))]
                        (if (= :forcebreak (:t it))
                          (dec j)
                          (let [[cursor fresh pb pd last-cursor]
                                (case (:t it)
                                  :line (let [bl (vl/baseline fresh cursor pb pd (:ascent it) (:leading it) line-skip)
                                              c (+ bl (long (:depth it)))]
                                          [c false bl (long (:depth it)) c])
                                  :glue [(+ cursor (long (:h it))) true pb pd last-cursor]
                                  :rule (let [c (+ cursor (long (:thick it)))] [c true pb pd c])
                                  :row (let [c (+ cursor (long (:height it)))] [c true pb pd c])
                                  :floatmark [cursor fresh pb pd cursor])
                                [fs seen-notes] (if (and (= :line (:t it)) (seq (:notes it)))
                                                  (reduce (fn [[fs seen] nn]
                                                            (if (seen nn)
                                                              [fs seen]
                                                              [(fn-state-add-group fs (notes nn) item-space line-skip)
                                                               (conj seen nn)]))
                                                          [fs seen-notes] (:notes it))
                                                  [fs seen-notes])
                                a-fn (if (pos? (long (nth fs 4))) (+ fn-fixed (long (nth fs 0))) 0)
                                used (+ (- last-cursor body-top) (min a-fn max-h))]
                            (cond
                              (> used goal)
                              (if (>= best 0)
                                best
                                (or (first (filter #(aget legal %) (range (inc i) (inc n)))) n))
                              :else
                              (let [best (if (aget legal j) j best)]
                                (if (== j n)
                                  best
                                  (recur (inc j) (long cursor) fresh (long pb) (long pd) (long last-cursor) fs seen-notes (long best))))))))))
                  n)
                ;; ---- step 4: place the body
                end (loop [e cut] (if (and (> e i) (= :glue (:t (nth items (dec e))))) (recur (dec e)) e))
                placed (place-body items i end body-top line-skip)
                b-used (long (:used placed))
                body-empty? (== end i)
                ;; ---- step 5: footnotes
                refs (distinct (mapcat #(when (= :line (:t %)) (:notes %)) (subvec items i end)))
                cand (vec (concat carried (map (fn [nn] (assoc (notes nn) :mark? true)) refs)))
                total (reduce + 0 (map #(count (:lines %)) cand))
                avail (- goal b-used fn-fixed)
                heights (group-line-heights cand item-space line-skip)
                p0 (count (take-while (fn [[_ _ h]] (<= (long h) avail)) heights))
                p1 (if (and (pos? p0) (< p0 total))
                     (let [[gi li _] (nth heights (dec p0))
                           q (inc (long li))
                           gsize (count (:lines (nth cand gi)))]
                       (if (and (< q gsize) (< q min-split) (> (- p0 q) 0)) (- p0 q) p0))
                     p0)
                p (if (and body-empty? (zero? p1) (pos? total)) 1 p1)
                ;; split the candidates into placed groups and the carry
                [placed-groups carry]
                (loop [gs (seq cand) left p pg [] cy []]
                  (if gs
                    (let [g (first gs) c (count (:lines g))]
                      (cond
                        (zero? left) (recur (next gs) 0 pg (conj cy g))
                        (>= left c) (recur (next gs) (- left c) (conj pg g) cy)
                        :else (recur (next gs) 0
                                     (conj pg (assoc g :lines (subvec (vec (:lines g)) 0 left)))
                                     (conj cy (assoc g :lines (subvec (vec (:lines g)) left) :mark? false)))))
                    [pg cy]))
                h-fn (if (pos? p) (long (nth (nth heights (dec p)) 2)) 0)
                fn-out (when (pos? p) (place-footnotes env placed-groups h-fn))
                page-items (-> []
                               (into (place-figures env taken))
                               (into (:out placed))
                               (into fn-out))
                queue'' (into queue' (:marks placed))
                split' (long (+ split (reduce + 0 (map #(count (:lines %)) carry))))]
            (recur (long cut) queue'' carry
                   (conj pages {:out page-items :heads (:heads placed)})
                   split')))))))
