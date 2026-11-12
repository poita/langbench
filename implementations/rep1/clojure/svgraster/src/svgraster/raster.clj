(ns svgraster.raster
  "Canvas, scanline polygon filler with anti-aliasing, compositing and PPM
  output.

  A canvas is `W x H` pixels of premultiplied RGBA doubles (all channels `0`
  initially, i.e. transparent), stored interleaved in a single `double[]`.

  Coverage is computed by an active-edge-table sweep over 64 sub-scanlines
  per pixel row. Each sub-scanline is intersected exactly with the polygon
  edges; the resulting x spans are accumulated into per-pixel coverage with a
  difference array so that a span costs O(1) regardless of its length. Only
  sub-scanlines that have active edges, and only the pixels of the rows that
  are touched, are visited."
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)

(def ^:const sub-scanlines 64)

(defrecord Canvas [^long width ^long height ^doubles data ^doubles acc ^doubles diff])

(defn new-canvas
  "A transparent canvas of `width` x `height` pixels."
  ^Canvas [^long width ^long height]
  (->Canvas width height
            (double-array (* 4 width height))
            (double-array (+ width 2))
            (double-array (+ width 2))))

;; ---------------------------------------------------------------------------
;; Polygon orientation

(defn signed-area
  "Shoelace signed area of a flat x,y polygon."
  ^double [^doubles pts]
  (let [n (quot (alength pts) 2)]
    (loop [i 0 sum 0.0]
      (if (< i n)
        (let [j (if (== (inc i) n) 0 (inc i))
              x0 (aget pts (* 2 i)) y0 (aget pts (inc (* 2 i)))
              x1 (aget pts (* 2 j)) y1 (aget pts (inc (* 2 j)))]
          (recur (inc i) (+ sum (- (* x0 y1) (* x1 y0)))))
        (* 0.5 sum)))))

(defn orient-positive
  "Returns `pts` with the vertex order reversed if its signed area is
  negative, so that all pieces of a union wind the same way."
  ^doubles [^doubles pts]
  (if (neg? (signed-area pts))
    (let [n (quot (alength pts) 2)
          out (double-array (alength pts))]
      (dotimes [i n]
        (let [k (- n 1 i)]
          (aset out (* 2 i) (aget pts (* 2 k)))
          (aset out (inc (* 2 i)) (aget pts (inc (* 2 k))))))
      out)
    pts))

;; ---------------------------------------------------------------------------
;; Filling

(defn- flush-row!
  "Converts the accumulated coverage of pixel row `row` (columns `minx` ..
  `maxx`) into composited pixels and clears the accumulators."
  [^Canvas canvas row minx maxx cr cg cb pa]
  (let [row (long row) minx (long minx) maxx (long maxx)
        ^doubles data (.data canvas)
        ^doubles acc (.acc canvas)
        ^doubles diff (.diff canvas)
        w (.width canvas)
        cr (double cr) cg (double cg) cb (double cb) pa (double pa)
        base (* 4 row w)]
    (loop [x minx run 0.0]
      (when (<= x maxx)
        (let [run (+ run (aget diff x))
              cov (Math/min 1.0 (+ (aget acc x) run))
              alpha (* pa cov)]
          (when (> alpha 1.0e-12)
            (let [i (+ base (* 4 x))
                  inv (- 1.0 alpha)]
              (aset data i (+ (* cr alpha) (* (aget data i) inv)))
              (aset data (+ i 1) (+ (* cg alpha) (* (aget data (+ i 1)) inv)))
              (aset data (+ i 2) (+ (* cb alpha) (* (aget data (+ i 2)) inv)))
              (aset data (+ i 3) (+ alpha (* (aget data (+ i 3)) inv)))))
          (aset acc x 0.0)
          (aset diff x 0.0)
          (recur (inc x) run))))
    (aset diff (inc maxx) 0.0)))

(defn- add-span!
  "Adds the span [xa, xb) of one sub-scanline to the row accumulators.
  Returns nothing; updates `st` (a long[] with min/max touched column)."
  [^doubles acc ^doubles diff ^longs st w xa xb]
  (let [w (long w) xa (double xa) xb (double xb)
        x0 (Math/max 0.0 xa)
        x1 (Math/min (double w) xb)]
    (when (> x1 x0)
      (let [wt (/ 1.0 sub-scanlines)
            i0 (long (Math/floor x0))
            i1 (long (Math/floor x1))]
        (if (== i0 i1)
          (aset acc i0 (+ (aget acc i0) (* (- x1 x0) wt)))
          (do
            (aset acc i0 (+ (aget acc i0) (* (- (+ i0 1.0) x0) wt)))
            (aset acc i1 (+ (aget acc i1) (* (- x1 i1) wt)))
            (aset diff (inc i0) (+ (aget diff (inc i0)) wt))
            (aset diff i1 (- (aget diff i1) wt))))
        (when (< i0 (aget st 2)) (aset st 2 i0))
        (let [hi (Math/min i1 (dec w))]
          (when (> hi (aget st 3)) (aset st 3 hi)))))))

(defn fill-polygons!
  "Fills the region described by `polygons` (a sequence of closed polygons,
  each a flat `double[]` of device-space x,y pairs) onto `canvas` with the
  colour `[r g b]` (doubles in 0..1) at paint opacity `opacity`.
  `rule` is `:nonzero` or `:evenodd`. Pixel coverage is the mean over 64
  sub-scanlines of the covered span length."
  [^Canvas canvas polygons rule [cr cg cb] opacity]
  (let [w (.width canvas)
        h (.height canvas)
        ^doubles acc (.acc canvas)
        ^doubles diff (.diff canvas)
        evenodd? (= rule :evenodd)
        max-edges (long (reduce (fn [^long a ^doubles p] (+ a (quot (alength p) 2))) 0 polygons))
        ex (double-array max-edges)     ; x of the edge at y = ey0
        ey (double-array max-edges)     ; y0 (top end)
        slope (double-array max-edges)  ; dx/dy
        edir (long-array max-edges)
        es0 (long-array max-edges)      ; first sub-scanline sampled
        es1 (long-array max-edges)      ; last sub-scanline sampled
        last-sub (dec (* sub-scanlines h))
        ne (long
            (reduce
             (fn [^long ne ^doubles p]
               (let [np (quot (alength p) 2)]
                 (loop [k 0 ne ne]
                   (if (< k np)
                     (let [k2 (if (== (inc k) np) 0 (inc k))
                           xa (aget p (* 2 k)) ya (aget p (inc (* 2 k)))
                           xb (aget p (* 2 k2)) yb (aget p (inc (* 2 k2)))]
                       (if (and (not (== ya yb))
                                (Double/isFinite xa) (Double/isFinite ya)
                                (Double/isFinite xb) (Double/isFinite yb))
                         (let [down? (< ya yb)
                               x0 (if down? xa xb) y0 (if down? ya yb)
                               x1 (if down? xb xa) y1 (if down? yb ya)
                               s0 (Math/max 0 (long (Math/ceil (- (* y0 sub-scanlines) 0.5))))
                               s1 (Math/min last-sub (dec (long (Math/ceil (- (* y1 sub-scanlines) 0.5)))))]
                           (if (<= s0 s1)
                             (do (aset ex ne x0) (aset ey ne y0)
                                 (aset slope ne (/ (- x1 x0) (- y1 y0)))
                                 (aset edir ne (if down? 1 -1))
                                 (aset es0 ne s0) (aset es1 ne s1)
                                 (recur (inc k) (inc ne)))
                             (recur (inc k) ne)))
                         (recur (inc k) ne)))
                     ne))))
             0 polygons))]
    (when (pos? ne)
      (let [keys (long-array ne)
            _ (dotimes [i ne] (aset keys i (bit-or (bit-shift-left (aget es0 i) 32) i)))
            _ (Arrays/sort keys)
            aidx (long-array ne)
            ax (double-array ne)
            st (long-array [0 0 w -1]) ; [unused unused minx maxx]
            r (double cr) g (double cg) b (double cb) pa (double opacity)
            flush! (fn [^long row]
                     (when (<= (aget st 2) (aget st 3))
                       (flush-row! canvas row (aget st 2) (aget st 3) r g b pa))
                     (aset st 2 w)
                     (aset st 3 -1))]
        (loop [s (bit-shift-right (aget keys 0) 32) ptr 0 na 0 row -1]
          (let [srow (bit-shift-right s 6)
                _ (when (and (not (== srow row)) (>= row 0)) (flush! row))
                ;; drop edges that ended before this sub-scanline
                na (loop [i 0 j 0]
                     (if (< i na)
                       (let [e (aget aidx i)]
                         (if (>= (aget es1 e) s)
                           (do (aset aidx j e) (recur (inc i) (inc j)))
                           (recur (inc i) j)))
                       j))
                ;; add edges that start here
                new-ptr (loop [p ptr]
                          (if (and (< p ne) (<= (bit-shift-right (aget keys p) 32) s))
                            (recur (inc p))
                            p))
                na (loop [p ptr na na]
                     (if (< p new-ptr)
                       (do (aset aidx na (bit-and (aget keys p) 0xFFFFFFFF))
                           (recur (inc p) (inc na)))
                       na))
                ptr new-ptr]
            (if (zero? na)
              (if (>= ptr ne)
                (flush! srow)
                (recur (bit-shift-right (aget keys ptr) 32) ptr 0 srow))
              (let [ys (/ (+ s 0.5) sub-scanlines)]
                ;; x of each active edge at this sub-scanline
                (dotimes [i na]
                  (let [e (aget aidx i)]
                    (aset ax i (+ (aget ex e) (* (- ys (aget ey e)) (aget slope e))))))
                ;; insertion sort by x (the order is nearly stable between lines)
                (loop [i 1]
                  (when (< i na)
                    (let [xv (aget ax i) ev (aget aidx i)]
                      (loop [j (dec i)]
                        (if (and (>= j 0) (> (aget ax j) xv))
                          (do (aset ax (inc j) (aget ax j))
                              (aset aidx (inc j) (aget aidx j))
                              (recur (dec j)))
                          (do (aset ax (inc j) xv)
                              (aset aidx (inc j) ev)))))
                    (recur (inc i))))
                ;; sweep the crossings
                (loop [i 0 wind 0 start 0.0]
                  (when (< i na)
                    (let [e (aget aidx i)
                          x (aget ax i)
                          before (if evenodd? (odd? wind) (not (zero? wind)))
                          wind (+ wind (aget edir e))
                          after (if evenodd? (odd? wind) (not (zero? wind)))]
                      (cond
                        (and (not before) after) (recur (inc i) wind x)
                        (and before (not after)) (do (add-span! acc diff st w start x)
                                                     (recur (inc i) wind start))
                        :else (recur (inc i) wind start)))))
                (recur (inc s) ptr na srow)))))))
    nil))

;; ---------------------------------------------------------------------------
;; Compositing and output

(defn composite-layer!
  "Composites the transparent `layer` onto `dst` with group opacity `o`:
  `dst = src*o + dst*(1 - src.a*o)` for every channel including alpha."
  [^Canvas dst ^Canvas layer ^double o]
  (let [^doubles d (.data dst)
        ^doubles s (.data layer)
        n (alength d)]
    (loop [i 0]
      (when (< i n)
        (let [sa (aget s (+ i 3))]
          (when (> sa 0.0)
            (let [inv (- 1.0 (* sa o))]
              (aset d i (+ (* (aget s i) o) (* (aget d i) inv)))
              (aset d (+ i 1) (+ (* (aget s (+ i 1)) o) (* (aget d (+ i 1)) inv)))
              (aset d (+ i 2) (+ (* (aget s (+ i 2)) o) (* (aget d (+ i 2)) inv)))
              (aset d (+ i 3) (+ (* sa o) (* (aget d (+ i 3)) inv))))))
        (recur (+ i 4))))
    nil))

(defn- to-byte ^long [^double v]
  (long (Math/floor (+ (* (Math/max 0.0 (Math/min 1.0 v)) 255.0) 0.5))))

(defn ->rgb-bytes
  "Composites `canvas` over opaque white and returns the `W*H*3` bytes of the
  image, rows top to bottom, as a `byte[]`."
  ^bytes [^Canvas canvas]
  (let [^doubles d (.data canvas)
        n (* (.width canvas) (.height canvas))
        out (byte-array (* 3 n))]
    (dotimes [p n]
      (let [i (* 4 p)
            inv (- 1.0 (aget d (+ i 3)))]
        (aset out (* 3 p) (unchecked-byte (to-byte (+ (aget d i) inv))))
        (aset out (+ (* 3 p) 1) (unchecked-byte (to-byte (+ (aget d (+ i 1)) inv))))
        (aset out (+ (* 3 p) 2) (unchecked-byte (to-byte (+ (aget d (+ i 2)) inv))))))
    out))

(defn ->ppm
  "The binary PPM (P6) file contents for `canvas` as a `byte[]`."
  ^bytes [^Canvas canvas]
  (let [header (.getBytes (str "P6\n" (.width canvas) " " (.height canvas) "\n255\n")
                          java.nio.charset.StandardCharsets/US_ASCII)
        ^bytes body (->rgb-bytes canvas)
        out (byte-array (+ (alength header) (alength body)))]
    (System/arraycopy header 0 out 0 (alength header))
    (System/arraycopy body 0 out (alength header) (alength body))
    out))
