(ns typeset.linebreak
  "Total-fit line breaking over a horizontal list.

  Candidate lines are measured in O(1) with prefix sums. Pass 1 only admits
  feasible lines and drops nodes whose line has become overfull; pass 2 (used
  when pass 1 finds no breaking) admits every line and prunes nothing."
  (:require [typeset.hlist :as hl]
            [typeset.util :as u]))

(set! *warn-on-reflection* true)

(defn- fit-code
  "Classify a line with `d = L - W`, stretch `y`, shrink `z` and `inf` = 1 when
  it holds the infinite glue. Returns -1 (unstretchable), -2 (overfull) or
  `badness * 4 + fitness-class`."
  ^long [^long d ^long y ^long z ^long inf]
  (cond
    (and (>= d 0) (== inf 1)) 1
    (zero? d) 1
    (pos? d) (if (zero? y)
               -1
               (let [b (u/cube-ratio d y)]
                 (+ (* 4 b) (cond (> d y) 3 (> (* 2 d) y) 2 :else 1))))
    :else (let [e (- d)]
            (if (or (zero? z) (> e z))
              -2
              (let [b (u/cube-ratio e z)]
                (+ (* 4 b) (if (> (* 2 e) z) 0 1)))))))

(defn- prefix ^longs [^longs a ^long n]
  (let [p (long-array (inc n))]
    (dotimes [i n] (aset p (inc i) (+ (aget p i) (aget a i))))
    p))

(defn- run-pass
  "One pass of the algorithm. Returns `{:total :breaks}` or nil when no node
  exists at the final breakpoint."
  [{:keys [n w y z inf pen flag pre kind]}
   bpi measure first-indent pass2?
   {:keys [tolerance line-penalty adj double-hyphen final-hyphen]}]
  (let [n (long n) ^longs w w ^longs y y ^longs z z ^booleans inf inf ^longs pen pen
        ^booleans flag flag ^longs pre pre ^bytes kind kind ^ints bpi bpi
        measure (long measure) first-indent (long first-indent)
        tolerance (long tolerance) line-penalty (long line-penalty) adj (long adj)
        double-hyphen (long double-hyphen) final-hyphen (long final-hyphen)
        B (dec (alength bpi))
        ^longs pw (prefix (let [a (long-array n)] (dotimes [i n] (aset a i (aget w i))) a) n)
        ^longs py (prefix y n)
        ^longs pz (prefix z n)
        ^longs pinf (prefix (let [a (long-array n)] (dotimes [i n] (when (aget inf i) (aset a i 1))) a) n)
        cap (+ 8 (* 4 (inc B)))
        ^ints nbp (int-array cap) ^ints ncls (int-array cap) ^longs ntot (long-array cap) ^ints nprev (int-array cap)
        ^ints active (int-array cap)
        ^longs best-total (long-array 4)
        ^ints best-prev (int-array 4)
        pass2? (boolean pass2?)]
    ;; node 0: the start
    (aset nbp 0 0) (aset ncls 0 1) (aset ntot 0 0) (aset nprev 0 -1)
    (aset active 0 0)
    (loop [bi 1 nn 1 na 1 final-from 0]
      (if (> bi B)
        ;; read off the best node at the final breakpoint
        (when (< final-from nn)
          (let [best (long (loop [k (inc final-from) best final-from]
                       (if (< k nn)
                         (recur (inc k) (if (< (aget ntot k) (aget ntot best)) k best))
                         best)))]
            {:total (aget ntot best)
             :breaks (loop [k best out ()]
                       (if (zero? k) (vec out) (recur (aget nprev k) (cons (aget bpi (aget nbp k)) out))))}))
        (let [nn0 nn
              b (aget bpi bi)
              is-final (== bi B)
              p (if (== (aget kind b) hl/PENALTY) (aget pen b) 0)
              fb (aget flag b)
              prew (if (== (aget kind b) hl/PENALTY) (aget pre b) 0)
              _ (java.util.Arrays/fill best-total Long/MAX_VALUE)
              _ (java.util.Arrays/fill best-prev -1)
              pen-dem (cond (and (<= 0 p) (< p 10000)) (* p p)
                            (and (< -10000 p) (< p 0)) (- (* p p))
                            :else 0)
              ;; scan active nodes in node order, compacting in pass 1
              kept (long (loop [k 0 kept 0]
                     (if (< k na)
                       (let [node (aget active k)
                             a (aget bpi (aget nbp node))
                             s (if (zero? a) 0 (inc a))
                             wn (- (aget pw b) (aget pw s))
                             zz (- (aget pz b) (aget pz s))
                             lm (if (zero? a) (- measure first-indent) measure)]
                         (if (and (not pass2?) (> (- wn zz) lm))
                           (recur (inc k) kept)
                           (do
                             (when-not (== kept k) (aset active (int kept) (int node)))
                             (let [ww (+ wn prew)
                                   yy (- (aget py b) (aget py s))
                                   inf1 (if (pos? (- (aget pinf b) (aget pinf s))) 1 0)
                                   code (fit-code (- lm ww) yy zz inf1)
                                   code (if pass2?
                                          (cond (== code -1) (+ (* 4 10000) 3)
                                                (== code -2) (* 4 10000)
                                                :else code)
                                          code)]
                               (when (and (>= code 0)
                                          (or pass2? (<= (quot code 4) tolerance)))
                                 (let [bad (quot code 4)
                                       c (rem code 4)
                                       c0 (aget ncls node)
                                       fa (aget flag a)
                                       dem (+ (* (+ line-penalty bad) (+ line-penalty bad))
                                              pen-dem
                                              (if (and fb fa) double-hyphen 0)
                                              (if (> (Math/abs (long (- c c0))) 1) adj 0)
                                              (if (and is-final fa) final-hyphen 0))
                                       total (long (+ (aget ntot node) dem))]
                                   (when (< total (aget best-total c))
                                     (aset best-total c total)
                                     (aset best-prev c (int node))))))
                             (recur (inc k) (inc kept)))))
                       kept)))
              ;; create the new nodes, in class order
              nn2 (long (loop [c 0 q nn]
                          (if (< c 4)
                            (if (>= (aget best-prev c) 0)
                              (do (aset nbp q (int bi)) (aset ncls q (int c))
                                  (aset ntot q (aget best-total c))
                                  (aset nprev q (aget best-prev c))
                                  (aset active (+ kept (- q nn)) (int q))
                                  (recur (inc c) (inc q)))
                              (recur (inc c) q))
                            q)))
              na2 (+ kept (- nn2 nn))]
          (if (and (not pass2?) (zero? na2))
            nil
            (recur (inc bi) nn2 na2 (if is-final nn0 final-from))))))))

(defn break-list
  "Break horizontal list `hl` into lines for lines of width `measure`, the first
  shortened by `first-indent`. `params` holds `:tolerance :line-penalty :adj
  :double-hyphen :final-hyphen`. Returns `{:total :breaks :emergency?}` where
  `:breaks` are the item indices of the chosen breakpoints, in order."
  [hl measure first-indent params]
  (let [bpi (int-array (cons 0 (hl/breakpoints hl)))]
    (if-let [r (run-pass hl bpi measure first-indent false params)]
      (assoc r :emergency? false)
      (assoc (run-pass hl bpi measure first-indent true params) :emergency? true))))

(defn params
  "Line-breaking parameters from a settings map."
  [settings]
  {:tolerance (settings "tolerance")
   :line-penalty (settings "line-penalty")
   :adj (settings "adj-demerits")
   :double-hyphen (settings "double-hyphen-demerits")
   :final-hyphen (settings "final-hyphen-demerits")})

(defn min-width
  "The largest natural width of any line between consecutive breakpoints of
  `hl` (breakpoint 0 and the final breakpoint included)."
  ^long [{:keys [^longs w ^longs pre ^bytes kind]} bps]
  (let [bpi (int-array (cons 0 bps))]
    (loop [bi 1 best 0]
      (if (< bi (alength bpi))
        (let [a (aget bpi (dec bi)) b (aget bpi bi)
              s (if (zero? a) 0 (inc a))
              wsum (loop [i s acc 0] (if (< i b) (recur (inc i) (+ acc (aget w i))) acc))
              wsum (long (+ wsum (if (== (aget kind b) hl/PENALTY) (aget pre b) 0)))]
          (recur (inc bi) (max best wsum)))
        best))))
