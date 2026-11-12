(ns svgraster.path
  "Paths: SVG path data parsing, elliptical arcs, shapes as paths and cubic
  flattening.

  A *path* is a vector of absolute segments

      [:M x y]  [:L x y]  [:C x1 y1 x2 y2 x y]  [:Z]

  Every command of the path-data grammar and every basic shape is reduced to
  these four. A drawing command that follows a `:Z` is preceded by an
  explicit `[:M sx sy]` at the start point of the closed subpath.

  *Flattening* turns a path into a vector of subpaths
  `{:points double[] :closed? bool}` where `:points` holds x,y pairs."
  (:require [svgraster.buf :as buf]
            [svgraster.parse :as p]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Elliptical arcs (SVG 1.1 implementation notes F.6.5 and F.6.6)

(defn arc->segments
  "Converts the endpoint-parameterised arc from (x1, y1) to (x2, y2) into
  path segments: `[]` when the end points coincide, a single `[:L x2 y2]`
  when a radius is zero, otherwise cubic segments of at most 45 degrees.
  `phi` is the x-axis rotation in degrees."
  [x1 y1 rx ry phi large? sweep? x2 y2]
  (let [x1 (double x1) y1 (double y1) x2 (double x2) y2 (double y2)]
    (cond
      (and (== x1 x2) (== y1 y2)) []
      (or (zero? (double rx)) (zero? (double ry))) [[:L x2 y2]]
      :else
      (let [rx (Math/abs (double rx))
            ry (Math/abs (double ry))
            phi-r (Math/toRadians (double phi))
            cos-phi (Math/cos phi-r)
            sin-phi (Math/sin phi-r)
            dx2 (/ (- x1 x2) 2.0)
            dy2 (/ (- y1 y2) 2.0)
            x1p (+ (* cos-phi dx2) (* sin-phi dy2))
            y1p (+ (* (- sin-phi) dx2) (* cos-phi dy2))
            lam (+ (/ (* x1p x1p) (* rx rx)) (/ (* y1p y1p) (* ry ry)))
            scale (if (> lam 1.0) (Math/sqrt lam) 1.0)
            rx (* rx scale)
            ry (* ry scale)
            rx2 (* rx rx) ry2 (* ry ry)
            num (- (* rx2 ry2) (* rx2 y1p y1p) (* ry2 x1p x1p))
            den (+ (* rx2 y1p y1p) (* ry2 x1p x1p))
            coef (let [c (Math/sqrt (Math/max 0.0 (/ num den)))]
                   (if (= (boolean large?) (boolean sweep?)) (- c) c))
            cxp (* coef (/ (* rx y1p) ry))
            cyp (* coef (- (/ (* ry x1p) rx)))
            cx (+ (* cos-phi cxp) (* (- sin-phi) cyp) (/ (+ x1 x2) 2.0))
            cy (+ (* sin-phi cxp) (* cos-phi cyp) (/ (+ y1 y2) 2.0))
            ux (/ (- x1p cxp) rx)
            uy (/ (- y1p cyp) ry)
            vx (/ (- (- x1p) cxp) rx)
            vy (/ (- (- y1p) cyp) ry)
            theta1 (Math/atan2 uy ux)
            dtheta (let [d (Math/atan2 (- (* ux vy) (* uy vx)) (+ (* ux vx) (* uy vy)))
                         two-pi (* 2.0 Math/PI)]
                     (cond
                       (and (not sweep?) (> d 0.0)) (- d two-pi)
                       (and sweep? (< d 0.0)) (+ d two-pi)
                       :else d))
            n (Math/max 1 (long (Math/ceil (/ (Math/abs (double dtheta)) (/ Math/PI 4.0)))))
            delta (/ dtheta n)
            k (* (/ 4.0 3.0) (Math/tan (/ delta 4.0)))
            point (fn [t]
                    (let [c (Math/cos t) s (Math/sin t)]
                      [(+ cx (* cos-phi rx c) (* (- sin-phi) ry s))
                       (+ cy (* sin-phi rx c) (* cos-phi ry s))]))
            deriv (fn [t]
                    (let [c (Math/cos t) s (Math/sin t)]
                      [(+ (* cos-phi (- (* rx s))) (* (- sin-phi) ry c))
                       (+ (* sin-phi (- (* rx s))) (* cos-phi ry c))]))]
        (vec
         (for [i (range n)]
           (let [t0 (+ theta1 (* i delta))
                 t1 (+ t0 delta)
                 [p0x p0y] (point t0)
                 [p3x p3y] (if (== i (dec n)) [x2 y2] (point t1))
                 [d0x d0y] (deriv t0)
                 [d1x d1y] (deriv t1)]
             [:C (+ p0x (* k d0x)) (+ p0y (* k d0y))
              (- (nth (point t1) 0) (* k d1x)) (- (nth (point t1) 1) (* k d1y))
              p3x p3y])))))))

;; ---------------------------------------------------------------------------
;; Path data

(def ^:private arity
  {\M 2 \L 2 \H 1 \V 1 \C 6 \S 4 \Q 4 \T 2 \A 7 \Z 0})

(defn- read-params
  "Reads the `n` parameters of a command at `pos`. Arc flags (parameters 3 and
  4 of `A`) are single characters. Returns `[values end]` or nil."
  [^String s ^long pos cmd ^long n]
  (loop [k 0 pos pos acc []]
    (if (== k n)
      [acc pos]
      (let [pos (p/skip-separators s pos)]
        (if (>= pos (.length s))
          nil
          (if (and (= cmd \A) (or (== k 3) (== k 4)))
            (let [c (.charAt s pos)]
              (when (or (= c \0) (= c \1))
                (recur (inc k) (inc pos) (conj acc (if (= c \1) 1.0 0.0)))))
            (when-let [[v e] (p/parse-number-at s pos)]
              (recur (inc k) (long e) (conj acc v)))))))))

(defn- quad->cubic
  "The cubic equal to the quadratic from (cx, cy) via (qx, qy) to (x, y)."
  [cx cy qx qy x y]
  (let [k (/ 2.0 3.0)]
    [:C (+ cx (* k (- qx cx))) (+ cy (* k (- qy cy)))
     (+ x (* k (- qx x))) (+ y (* k (- qy y)))
     x y]))

(defn- apply-command
  "Applies the command `upper` (an upper-case letter; `rel?` when it was
  written in lower case) with parameters `v` to the parser state and returns
  the new state. The state holds the current point `:cx :cy`, the subpath
  start `:sx :sy`, whether a subpath is `:open?`, the previous cubic/quad
  control points `:prev-c :prev-q` and the output `:segs`."
  [{:keys [cx cy sx sy open? prev-c prev-q segs] :as st} upper rel? v]
  (let [cx (double cx) cy (double cy)
        ox (if rel? cx 0.0)
        oy (if rel? cy 0.0)
        ;; a drawing command after Z starts a new subpath at the old start
        segs (if (and (not= upper \M) (not open?)) (conj segs [:M sx sy]) segs)
        n (fn [i] (double (v i)))
        move (fn [x y seg & [c q]]
               (assoc st :cx x :cy y :open? true :prev-c c :prev-q q
                      :segs (conj segs seg)))]
    (case upper
      \M (let [x (+ ox (n 0)) y (+ oy (n 1))]
           (assoc st :cx x :cy y :sx x :sy y :open? true
                  :prev-c nil :prev-q nil :segs (conj segs [:M x y])))
      \L (let [x (+ ox (n 0)) y (+ oy (n 1))] (move x y [:L x y]))
      \H (let [x (+ ox (n 0))] (move x cy [:L x cy]))
      \V (let [y (+ oy (n 0))] (move cx y [:L cx y]))
      \C (let [x2 (+ ox (n 2)) y2 (+ oy (n 3)) x (+ ox (n 4)) y (+ oy (n 5))]
           (move x y [:C (+ ox (n 0)) (+ oy (n 1)) x2 y2 x y] [x2 y2] nil))
      \S (let [x1 (if prev-c (- (* 2.0 cx) (double (prev-c 0))) cx)
               y1 (if prev-c (- (* 2.0 cy) (double (prev-c 1))) cy)
               x2 (+ ox (n 0)) y2 (+ oy (n 1)) x (+ ox (n 2)) y (+ oy (n 3))]
           (move x y [:C x1 y1 x2 y2 x y] [x2 y2] nil))
      \Q (let [qx (+ ox (n 0)) qy (+ oy (n 1)) x (+ ox (n 2)) y (+ oy (n 3))]
           (move x y (quad->cubic cx cy qx qy x y) nil [qx qy]))
      \T (let [qx (if prev-q (- (* 2.0 cx) (double (prev-q 0))) cx)
               qy (if prev-q (- (* 2.0 cy) (double (prev-q 1))) cy)
               x (+ ox (n 0)) y (+ oy (n 1))]
           (move x y (quad->cubic cx cy qx qy x y) nil [qx qy]))
      \A (let [x (+ ox (n 5)) y (+ oy (n 6))
               arc (arc->segments cx cy (n 0) (n 1) (n 2)
                                  (== 1.0 (n 3)) (== 1.0 (n 4)) x y)]
           (assoc st :cx x :cy y :open? true :prev-c nil :prev-q nil
                  :segs (into segs arc))))))

(defn parse-path-data
  "Parses SVG path data `d` into a path of absolute segments. Parsing stops at
  the first token that is not the expected kind; what was parsed before is
  kept."
  [^String d]
  (let [len (.length d)]
    (loop [pos 0
           cmd nil
           st {:cx 0.0 :cy 0.0 :sx nil :sy nil :open? false
               :prev-c nil :prev-q nil :segs []}]
      (let [pos (p/skip-separators d pos)
            ch (when (< pos len) (.charAt d pos))
            letter? (and ch (Character/isLetter (char ch)))
            cmd (if letter? ch cmd)
            pos (if letter? (inc pos) pos)
            upper (when cmd (Character/toUpperCase (char cmd)))]
        (cond
          (nil? ch) (:segs st)
          (not (contains? arity upper)) (:segs st)
          ;; Z takes no parameters and does not repeat
          (= upper \Z)
          (recur pos nil
                 (if (:open? st)
                   (assoc st :cx (:sx st) :cy (:sy st) :open? false
                          :prev-c nil :prev-q nil :segs (conj (:segs st) [:Z]))
                   st))
          :else
          (let [[vals end] (read-params d pos upper (arity upper))]
            (if (or (nil? vals) (and (not= upper \M) (nil? (:sx st))))
              (:segs st)
              (recur (long end)
                     (if (= upper \M) (if (= cmd \m) \l \L) cmd)
                     (apply-command st upper (Character/isLowerCase (char cmd)) (vec vals))))))))))

;; ---------------------------------------------------------------------------
;; Shapes as paths

(defn rect-path
  "Path of a rectangle with optional corner radii `rx`, `ry` (nil when
  absent). Returns nil when nothing is drawn."
  [x y w h rx ry]
  (when (and (> w 0.0) (> h 0.0))
    (let [rx (if (and rx (>= rx 0.0)) rx (when rx 0.0))
          ry (if (and ry (>= ry 0.0)) ry (when ry 0.0))
          rx0 (or rx ry 0.0)
          ry0 (or ry rx 0.0)
          rx (Math/min (double rx0) (/ (double w) 2.0))
          ry (Math/min (double ry0) (/ (double h) 2.0))]
      (if (or (zero? rx) (zero? ry))
        [[:M x y] [:L (+ x w) y] [:L (+ x w) (+ y h)] [:L x (+ y h)] [:Z]]
        (let [arc (fn [x1 y1 x2 y2] (arc->segments x1 y1 rx ry 0.0 false true x2 y2))]
          (-> [[:M (+ x rx) y]
               [:L (- (+ x w) rx) y]]
              (into (arc (- (+ x w) rx) y (+ x w) (+ y ry)))
              (conj [:L (+ x w) (- (+ y h) ry)])
              (into (arc (+ x w) (- (+ y h) ry) (- (+ x w) rx) (+ y h)))
              (conj [:L (+ x rx) (+ y h)])
              (into (arc (+ x rx) (+ y h) x (- (+ y h) ry)))
              (conj [:L x (+ y ry)])
              (into (arc x (+ y ry) (+ x rx) y))
              (conj [:Z])))))))

(defn ellipse-path
  "Path of an ellipse; nil when a radius is not positive."
  [cx cy rx ry]
  (when (and (> rx 0.0) (> ry 0.0))
    (let [arc (fn [x1 y1 x2 y2] (arc->segments x1 y1 rx ry 0.0 false true x2 y2))]
      (-> [[:M (+ cx rx) cy]]
          (into (arc (+ cx rx) cy cx (+ cy ry)))
          (into (arc cx (+ cy ry) (- cx rx) cy))
          (into (arc (- cx rx) cy cx (- cy ry)))
          (into (arc cx (- cy ry) (+ cx rx) cy))
          (conj [:Z])))))

(defn line-path [x1 y1 x2 y2]
  [[:M x1 y1] [:L x2 y2]])

(defn polyline-path
  "Path through the points of a flat coordinate vector; `close?` appends a
  `:Z` (polygon). nil when there are no points."
  [coords close?]
  (let [pts (partition 2 coords)]
    (when (seq pts)
      (let [[[x0 y0] & more] pts]
        (cond-> (into [[:M x0 y0]] (map (fn [[x y]] [:L x y])) more)
          close? (conj [:Z]))))))

;; ---------------------------------------------------------------------------
;; Flattening

(def ^:private max-steps 1000)

(defn cubic-steps
  "Number of equal parameter steps used to flatten a cubic with control points
  (x0,y0) .. (x3,y3) to within `tol`."
  [x0 y0 x1 y1 x2 y2 x3 y3 tol]
  (let [x0 (double x0) y0 (double y0) x1 (double x1) y1 (double y1)
        x2 (double x2) y2 (double y2) x3 (double x3) y3 (double y3)
        tol (double tol)
        ax (+ (- x0 (* 2.0 x1)) x2) ay (+ (- y0 (* 2.0 y1)) y2)
        bx (+ (- x1 (* 2.0 x2)) x3) by (+ (- y1 (* 2.0 y2)) y3)
        m (Math/max (+ (* ax ax) (* ay ay)) (+ (* bx bx) (* by by)))
        n (Math/ceil (Math/sqrt (/ (* 0.75 (Math/sqrt m)) tol)))]
    (cond
      (Double/isNaN n) 1
      (>= n max-steps) max-steps
      (< n 1.0) 1
      :else (long n))))

(defn flatten-path
  "Flattens `path` after mapping its points through the matrix `mat`, with
  maximum deviation `tol` (in the units of the mapped space). Returns a
  vector of `{:points double[], :closed? bool}`. A subpath is only produced
  when it has a drawing command (a lone `M` yields nothing)."
  [path mat ^double tol]
  (let [[ma mb mc md me mf] mat
        ma (double ma) mb (double mb) mc (double mc) md (double md)
        me (double me) mf (double mf)
        out (volatile! (transient []))
        cur (volatile! nil)   ; buffer of the open subpath
        drawn (volatile! false)
        px (volatile! 0.0) py (volatile! 0.0)
        finish! (fn [closed?]
                  (when (and @cur @drawn)
                    (vswap! out conj! {:points (buf/->array @cur) :closed? closed?}))
                  (vreset! cur nil)
                  (vreset! drawn false))
        tx (fn ^double [^double x ^double y] (+ (* ma x) (* mc y) me))
        ty (fn ^double [^double x ^double y] (+ (* mb x) (* md y) mf))]
    (doseq [seg path]
      (case (nth seg 0)
        :M (let [x (tx (nth seg 1) (nth seg 2)) y (ty (nth seg 1) (nth seg 2))]
             (finish! false)
             (let [b (buf/double-buf)]
               (buf/add-point! b x y)
               (vreset! cur b)
               (vreset! px x) (vreset! py y)))
        :L (when @cur
             (let [x (tx (nth seg 1) (nth seg 2)) y (ty (nth seg 1) (nth seg 2))]
               (buf/add-point! @cur x y)
               (vreset! drawn true)
               (vreset! px x) (vreset! py y)))
        :C (when @cur
             (let [x0 @px y0 @py
                   x1 (tx (nth seg 1) (nth seg 2)) y1 (ty (nth seg 1) (nth seg 2))
                   x2 (tx (nth seg 3) (nth seg 4)) y2 (ty (nth seg 3) (nth seg 4))
                   x3 (tx (nth seg 5) (nth seg 6)) y3 (ty (nth seg 5) (nth seg 6))
                   n (cubic-steps x0 y0 x1 y1 x2 y2 x3 y3 tol)]
               (loop [i 1]
                 (when (< i n)
                   (let [t (/ (double i) (double n))
                         u (- 1.0 t)
                         b0 (* u u u) b1 (* 3.0 u u t) b2 (* 3.0 u t t) b3 (* t t t)]
                     (buf/add-point! @cur
                                     (+ (* b0 x0) (* b1 x1) (* b2 x2) (* b3 x3))
                                     (+ (* b0 y0) (* b1 y1) (* b2 y2) (* b3 y3))))
                   (recur (inc i))))
               (buf/add-point! @cur x3 y3)
               (vreset! drawn true)
               (vreset! px x3) (vreset! py y3)))
        :Z (when @cur
             (vreset! drawn true)
             (finish! true))))
    (finish! false)
    (persistent! @out)))
