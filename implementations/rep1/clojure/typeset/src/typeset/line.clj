(ns typeset.line
  "Setting lines: glue distribution, alignment, run merging and the vertical
  metrics of a line."
  (:require [typeset.hlist :as hl]
            [typeset.metrics :as m]
            [typeset.util :as u :refer [fdiv scale]]))

(set! *warn-on-reflection* true)

(defn context-metrics
  "`[ascent depth]` of an empty line in context `ctx`."
  [faces ctx]
  (let [face (faces (m/face-name (:family ctx) (:bold ctx) (:italic ctx)))
        size (long (:size ctx))]
    [(m/ascent face size) (m/descent face size)]))

(defn- distribute
  "Widths of glues with natural widths `ws` and weights `wts` after
  distributing `e` among them in proportion to the weights."
  [ws wts ^long e]
  (let [t (long (reduce + wts))]
    (loop [ws (seq ws) wts (seq wts) p 0 c-prev 0 out (transient [])]
      (if ws
        (let [p (+ p (long (first wts)))
              c (fdiv (* e p) t)]
          (recur (next ws) (next wts) p c (conj! out (+ (long (first ws)) (- c c-prev)))))
        (persistent! out)))))

(defn set-line
  "Set the line of items `s`..`b`-1 of `hlist` (plus the pre-break text of item
  `b`). `l` is the line's measure, `x-left` the x of its left edge. Returns a
  line map `{:runs :ascent :depth :leading :notes :hyph? :overfull? :x-end}`."
  [faces ctx {:keys [items ^longs w ^longs y ^longs z ^booleans inf ^bytes kind ^longs pre]} s b l x-left]
  (let [s (long s) b (long b) l (long l)
        pre-item (when (== (aget kind b) hl/PENALTY) (:pre (nth items b)))
        pre-w (if pre-item (long (:w pre-item)) 0)
        ;; totals
        [bw gw gy gz ginf]
        (loop [i s bw 0 gw 0 gy 0 gz 0 ginf false]
          (if (< i b)
            (let [k (aget kind i)]
              (cond
                (== k hl/BOX) (recur (inc i) (+ bw (aget w i)) gw gy gz ginf)
                (== k hl/GLUE) (recur (inc i) bw (+ gw (aget w i)) (+ gy (aget y i))
                                      (+ gz (aget z i)) (or ginf (aget inf i)))
                :else (recur (inc i) bw gw gy gz ginf)))
            [bw gw gy gz ginf]))
        wtot (+ bw gw pre-w)
        justify? (= :justify (:align ctx))
        e (- l wtot)
        glue-idx (filterv #(== (aget kind (long %)) hl/GLUE) (range s b))
        natural (mapv #(aget w (long %)) glue-idx)
        set-ws (cond
                 ginf (mapv (fn [i] (if (aget inf (long i)) 0 (aget w (long i)))) glue-idx)
                 (not justify?) natural
                 (zero? e) natural
                 (and (pos? e) (zero? gy)) natural
                 (and (neg? e) (zero? gz)) natural
                 (pos? e) (distribute natural (mapv #(aget y (long %)) glue-idx) e)
                 (<= (- e) gz) (distribute natural (mapv #(aget z (long %)) glue-idx) e)
                 :else (mapv (fn [i] (- (aget w (long i)) (aget z (long i)))) glue-idx))
        wset (+ bw pre-w (long (reduce + set-ws)))
        x0 (case (:align ctx)
             (:justify :left) x-left
             :right (+ x-left (- l wset))
             :center (+ x-left (fdiv (- l wset) 2)))
        faces* faces]
    (loop [i s gi 0 x x0 runs [] last-run nil mergeable? false asc nil dep nil notes []]
      (letfn [(add-box [it x runs last-run mergeable?]
                ;; returns [runs last-run] after adding text box `it` at x
                (if (and mergeable? last-run
                         (= (:frag last-run) (:frag it))
                         (= (:face last-run) (:face it))
                         (== (:size last-run) (:size it))
                         (== (:raise last-run) (:raise it)))
                  (let [nr (assoc last-run :text (str (:text last-run) (:text it))
                                  :w (+ (long (:w last-run)) (long (:w it))))]
                    [(conj (pop runs) nr) nr])
                  (let [nr {:text (:text it) :face (:face it) :size (:size it)
                            :raise (:raise it) :x x :w (:w it) :frag (:frag it)}]
                    [(conj runs nr) nr])))
              (metrics [it asc dep]
                (let [fc (faces* (:face it))
                      a (+ (m/ascent fc (:size it)) (long (:raise it)))
                      d (max 0 (- (m/descent fc (:size it)) (long (:raise it))))]
                  [(if asc (max (long asc) a) a) (if dep (max (long dep) d) d)]))]
        (if (< i b)
          (let [k (aget kind i) it (nth items i)]
            (cond
              (== k hl/BOX)
              (if (:text it)
                (let [[runs* last*] (add-box it x runs last-run mergeable?)
                      [a d] (metrics it asc dep)]
                  (recur (inc i) gi (+ x (long (:w it))) runs* last* true a d
                         (if (:note it) (conj notes (:note it)) notes)))
                (recur (inc i) gi (+ x (long (:w it))) runs last-run false asc dep notes))
              (== k hl/GLUE)
              (recur (inc i) (inc gi) (+ x (long (nth set-ws gi))) runs last-run false asc dep notes)
              :else
              (recur (inc i) gi x runs last-run mergeable? asc dep notes)))
          ;; pre-break text
          (let [[runs* _] (if pre-item (add-box pre-item x runs last-run mergeable?) [runs nil])
                [a d] (if pre-item (metrics pre-item asc dep) [asc dep])
                [a d] (if a [a d] (context-metrics faces ctx))
                x-end (+ x pre-w)]
            {:runs (mapv #(dissoc % :frag) runs*)
             :ascent a :depth d :leading (:leading ctx)
             :notes notes :hyph? (boolean pre-item)
             :overfull? (> wset l) :x-end x-end :x-start x0}))))))

(defn set-lines
  "Set all lines of `hlist` for chosen breakpoint item indices `breaks`.
  `ctx` supplies `:left :measure :align :leading`, `first-indent` the extra
  indent of the first line."
  [faces ctx hlist breaks first-indent]
  (let [measure (long (:measure ctx))
        left (long (:left ctx))
        fi (long first-indent)]
    (loop [a 0 bs (seq breaks) out []]
      (if bs
        (let [b (long (first bs))
              s (if (zero? a) 0 (inc a))
              first? (zero? a)
              l (if first? (- measure fi) measure)
              x (if first? (+ left fi) left)]
          (recur b (next bs) (conj out (set-line faces ctx hlist s b l x))))
        out))))
