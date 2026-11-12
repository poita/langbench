(ns svgraster.stroke
  "Stroke outlining.

  The outline of a stroked path is the union of simple convex pieces:
  a rectangle per segment, a join piece per joint, a cap piece per open end,
  and a disc or square for a subpath that collapses to a single point. Each
  piece is a closed polygon given as a flat `double[]` of x,y pairs. The
  pieces are meant to be filled together with the nonzero rule after being
  oriented consistently (see `svgraster.raster/orient-positive`)."
  (:require [svgraster.buf :as buf]))

(set! *warn-on-reflection* true)

(def ^:private max-arc-steps 1000)

(defn- arc-steps
  "Number of chords needed to approximate a circular arc of radius `r`
  sweeping `sweep` radians with sagitta at most `tol`."
  ^long [^double r ^double sweep ^double tol]
  (let [step (if (>= tol r) Math/PI (* 2.0 (Math/acos (- 1.0 (/ tol r)))))
        n (Math/ceil (/ (Math/abs sweep) step))]
    (cond (Double/isNaN n) 1
          (> n max-arc-steps) max-arc-steps
          (< n 1.0) 1
          :else (long n))))

(defn- poly
  "Builds a polygon array from numbers."
  ^doubles [& coords]
  (double-array coords))

(defn- sector
  "Pie slice: centre (px, py), then the arc from angle `a0` sweeping `sweep`
  with radius `r`."
  ^doubles [px py r a0 sweep tol]
  (let [px (double px) py (double py) r (double r) a0 (double a0)
        sweep (double sweep) tol (double tol)
        n (arc-steps r sweep tol)
        out (double-array (* 2 (+ n 2)))]
    (aset out 0 px)
    (aset out 1 py)
    (loop [i 0]
      (when (<= i n)
        (let [a (+ a0 (* sweep (/ (double i) (double n))))]
          (aset out (+ 2 (* 2 i)) (+ px (* r (Math/cos a))))
          (aset out (+ 3 (* 2 i)) (+ py (* r (Math/sin a)))))
        (recur (inc i))))
    out))

(defn- disc ^doubles [^double px ^double py ^double r ^double tol]
  (let [n (Math/max 8 (arc-steps r (* 2.0 Math/PI) tol))
        out (double-array (* 2 n))]
    (loop [i 0]
      (when (< i n)
        (let [a (* 2.0 Math/PI (/ (double i) (double n)))]
          (aset out (* 2 i) (+ px (* r (Math/cos a))))
          (aset out (inc (* 2 i)) (+ py (* r (Math/sin a)))))
        (recur (inc i))))
    out))

(defn- dedupe-points
  "Drops points equal to their predecessor and, for a closed subpath, a final
  point equal to the first. Returns `[xs ys n]` with xs, ys as double[]."
  [^doubles pts closed?]
  (let [np (quot (alength pts) 2)
        xs (double-array np)
        ys (double-array np)
        n (loop [i 0 n 0]
            (if (< i np)
              (let [x (aget pts (* 2 i)) y (aget pts (inc (* 2 i)))]
                (if (and (pos? n) (== x (aget xs (dec n))) (== y (aget ys (dec n))))
                  (recur (inc i) n)
                  (do (aset xs n x) (aset ys n y) (recur (inc i) (inc n)))))
              n))
        n (if (and closed? (> n 1)
                   (== (aget xs 0) (aget xs (dec n)))
                   (== (aget ys 0) (aget ys (dec n))))
            (dec n)
            n)]
    [xs ys n]))

(defn- cap-pieces
  "Cap at point (px, py); `ux`,`uy` is the unit direction out of the subpath."
  [cap px py ux uy r tol]
  (let [px (double px) py (double py) ux (double ux) uy (double uy)
        r (double r) tol (double tol)
        nx (* (- uy) r) ny (* ux r)]
    (case cap
      :square [(poly (+ px nx) (+ py ny)
                     (+ px nx (* ux r)) (+ py ny (* uy r))
                     (+ (- px nx) (* ux r)) (+ (- py ny) (* uy r))
                     (- px nx) (- py ny))]
      :round (let [n (arc-steps r Math/PI tol)
                   out (double-array (* 2 (inc n)))]
               (loop [i 0]
                 (when (<= i n)
                   (let [a (* Math/PI (/ (double i) (double n)))
                         c (Math/cos a) s (Math/sin a)]
                     (aset out (* 2 i) (+ px (* c nx) (* s ux r)))
                     (aset out (inc (* 2 i)) (+ py (* c ny) (* s uy r))))
                   (recur (inc i))))
               [out])
      [])))

(defn- join-piece
  "Join piece at point p between unit directions d0 (incoming) and d1
  (outgoing), or nil when none is needed."
  [join miter-limit px py d0x d0y d1x d1y r tol]
  (let [miter-limit (double miter-limit) px (double px) py (double py)
        d0x (double d0x) d0y (double d0y) d1x (double d1x) d1y (double d1y)
        r (double r) tol (double tol)
        cross (- (* d0x d1y) (* d0y d1x))
        dot (+ (* d0x d1x) (* d0y d1y))
        s (if (> cross 0.0) 1.0 -1.0)]
    (when-not (and (zero? cross) (> dot 0.0))
      (let [anx (* s d0y r) any (* s (- d0x) r)
            bnx (* s d1y r) bny (* s (- d1x) r)
            ax (+ px anx) ay (+ py any)
            bx (+ px bnx) by (+ py bny)
            bevel (fn [] (poly px py ax ay bx by))]
        (case join
          :round (let [sweep (if (zero? cross)
                               (* s Math/PI)
                               (Math/atan2 (- (* anx bny) (* any bnx))
                                           (+ (* anx bnx) (* any bny))))
                       a0 (Math/atan2 any anx)]
                   (sector px py r a0 sweep tol))
          :miter (let [ratio (if (> dot -1.0)
                               (/ 1.0 (Math/sqrt (/ (+ 1.0 dot) 2.0)))
                               Double/POSITIVE_INFINITY)]
                   (if (and (> dot -1.0) (not (zero? cross)) (<= ratio miter-limit))
                     (let [k (/ 1.0 (+ 1.0 dot))
                           mx (+ px (* k (+ anx bnx)))
                           my (+ py (* k (+ any bny)))]
                       (poly px py ax ay mx my bx by))
                     (bevel)))
          (bevel))))))

(defn stroke-polygons
  "Outline pieces of the stroke of `subpaths` (as produced by
  `svgraster.path/flatten-path`).

  Options: `:width` (> 0), `:cap` (`:butt` `:round` `:square`), `:join`
  (`:miter` `:round` `:bevel`), `:miter-limit` and `:tolerance` (maximum
  deviation of round joins and caps, in the same units as the points).

  Returns a vector of polygons, each a `double[]` of x,y pairs."
  [subpaths {:keys [width cap join miter-limit tolerance]
             :or {cap :butt join :miter miter-limit 4.0 tolerance 0.01}}]
  (let [w (double width)
        r (/ w 2.0)
        tol (double tolerance)
        miter-limit (Math/max 1.0 (double miter-limit))]
    (into []
          (mapcat
           (fn [{:keys [^doubles points closed?]}]
             (let [[^doubles xs ^doubles ys n] (dedupe-points points closed?)
                   n (long n)]
               (cond
                 (== n 1)
                 (let [px (aget xs 0) py (aget ys 0)]
                   (case cap
                     :round [(disc px py r tol)]
                     :square [(poly (- px r) (- py r) (+ px r) (- py r)
                                    (+ px r) (+ py r) (- px r) (+ py r))]
                     []))

                 (>= n 2)
                 (let [nseg (if closed? n (dec n))
                       dxs (double-array nseg)
                       dys (double-array nseg)]
                   (dotimes [i nseg]
                     (let [j (rem (inc i) n)
                           dx (- (aget xs j) (aget xs i))
                           dy (- (aget ys j) (aget ys i))
                           len (Math/sqrt (+ (* dx dx) (* dy dy)))]
                       (aset dxs i (/ dx len))
                       (aset dys i (/ dy len))))
                   (let [segments
                         (for [i (range nseg)]
                           (let [j (rem (inc i) n)
                                 nx (* (- (aget dys i)) r) ny (* (aget dxs i) r)
                                 ax (aget xs i) ay (aget ys i)
                                 bx (aget xs j) by (aget ys j)]
                             (poly (+ ax nx) (+ ay ny) (+ bx nx) (+ by ny)
                                   (- bx nx) (- by ny) (- ax nx) (- ay ny))))
                         joint-idx (if closed? (range n) (range 1 (dec n)))
                         joints
                         (keep (fn [i]
                                 (let [prev (rem (+ (dec i) nseg) nseg)]
                                   (join-piece join miter-limit (aget xs i) (aget ys i)
                                               (aget dxs prev) (aget dys prev)
                                               (aget dxs i) (aget dys i) r tol)))
                               joint-idx)
                         caps (if closed?
                                []
                                (concat
                                 (cap-pieces cap (aget xs 0) (aget ys 0)
                                             (- (aget dxs 0)) (- (aget dys 0)) r tol)
                                 (cap-pieces cap (aget xs (dec n)) (aget ys (dec n))
                                             (aget dxs (dec nseg)) (aget dys (dec nseg)) r tol)))]
                     (concat segments joints caps)))

                 :else []))))
          subpaths)))
