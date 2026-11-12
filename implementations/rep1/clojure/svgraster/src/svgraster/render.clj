(ns svgraster.render
  "The document walk: property inheritance, transforms, `use`, group opacity
  and painting of shapes onto a `svgraster.raster` canvas."
  (:require [svgraster.color :as color]
            [svgraster.matrix :as m]
            [svgraster.parse :as p]
            [svgraster.path :as path]
            [svgraster.raster :as raster]
            [svgraster.stroke :as stroke]))

(set! *warn-on-reflection* true)

(def ^:private tolerance
  "Maximum deviation of flattened curves from the true curve, in device pixels."
  0.01)

(def ^:private max-depth 64)

(def ^:private shape-tags #{"path" "rect" "circle" "ellipse" "line" "polyline" "polygon"})
(def ^:private container-tags #{"g" "use"})

;; ---------------------------------------------------------------------------
;; Properties

(def initial-properties
  "Initial values of the inherited painting properties."
  {:fill [0 0 0]
   :fill-opacity 1.0
   :fill-rule :nonzero
   :stroke :none
   :stroke-width 1.0
   :stroke-linecap :butt
   :stroke-linejoin :miter
   :stroke-miterlimit 4.0
   :stroke-opacity 1.0
   :color [0 0 0]})

(defn- enum-parser [& options]
  (let [table (into {} (map (juxt name identity)) options)]
    (fn [raw _] (table raw))))

(defn- paint-parser [raw {:keys [color]}]
  (let [c (color/parse-color raw)]
    (if (= c :current) color c)))

(def ^:private property-parsers
  "Painting properties in resolution order (`color` first, so that
  `currentColor` sees the element's own colour)."
  [[:color "color" (fn [raw {:keys [parent]}]
                     (let [c (color/parse-color raw)]
                       (cond (= c :current) (:color parent)
                             (vector? c) c
                             :else nil)))]
   [:fill "fill" paint-parser]
   [:fill-opacity "fill-opacity" (fn [raw _] (p/parse-opacity raw))]
   [:fill-rule "fill-rule" (enum-parser :nonzero :evenodd)]
   [:stroke "stroke" paint-parser]
   [:stroke-width "stroke-width" (fn [raw _] (p/parse-length raw))]
   [:stroke-linecap "stroke-linecap" (enum-parser :butt :round :square)]
   [:stroke-linejoin "stroke-linejoin" (enum-parser :miter :round :bevel)]
   [:stroke-miterlimit "stroke-miterlimit" (fn [raw _] (p/parse-number raw))]
   [:stroke-opacity "stroke-opacity" (fn [raw _] (p/parse-opacity raw))]])

(defn- raw-property
  "The specified value of property `name`: the `style` declaration if there is
  one, else the presentation attribute, else nil."
  [attrs style ^String name]
  (or (get style name)
      (let [v (get attrs name)]
        (when (and v (seq (.trim ^String v))) v))))

(defn compute-properties
  "The computed painting properties of an element with `attrs` and parsed
  `style`, inheriting from `parent` (a map shaped like `initial-properties`).
  An unparsable value gives the property's initial value."
  [parent attrs style]
  (reduce
   (fn [props [k name parse-fn]]
     (if-let [raw (raw-property attrs style name)]
       (assoc props k (let [v (parse-fn raw {:parent parent :color (:color props)})]
                        (if (nil? v) (initial-properties k) v)))
       props))
   parent
   property-parsers))

;; ---------------------------------------------------------------------------
;; Painting

(defn- rgb->unit [[r g b]]
  [(/ (double r) 255.0) (/ (double g) 255.0) (/ (double b) 255.0)])

(defn- len
  "Length attribute `name` of `attrs`, `default` when missing or invalid."
  [attrs name default]
  (or (p/parse-length (get attrs name)) default))

(defn shape-path
  "The path of a shape element, or nil when nothing is drawn."
  [tag attrs]
  (case tag
    "path" (path/parse-path-data (get attrs "d" ""))
    "rect" (let [auto (fn [n] (p/parse-length (get attrs n)))]
             (path/rect-path (len attrs "x" 0.0) (len attrs "y" 0.0)
                             (len attrs "width" 0.0) (len attrs "height" 0.0)
                             (auto "rx") (auto "ry")))
    "circle" (let [r (len attrs "r" 0.0)]
               (path/ellipse-path (len attrs "cx" 0.0) (len attrs "cy" 0.0) r r))
    "ellipse" (path/ellipse-path (len attrs "cx" 0.0) (len attrs "cy" 0.0)
                                 (len attrs "rx" 0.0) (len attrs "ry" 0.0))
    "line" (path/line-path (len attrs "x1" 0.0) (len attrs "y1" 0.0)
                           (len attrs "x2" 0.0) (len attrs "y2" 0.0))
    "polyline" (path/polyline-path (let [v (p/parse-number-list (get attrs "points" ""))]
                                     (if (odd? (count v)) (pop v) v))
                                   false)
    "polygon" (path/polyline-path (let [v (p/parse-number-list (get attrs "points" ""))]
                                    (if (odd? (count v)) (pop v) v))
                                  true)
    nil))

(defn- paint-fill! [canvas segs ctm props]
  (let [fill (:fill props)
        opacity (:fill-opacity props)]
    (when (and (vector? fill) (> (double opacity) 0.0))
      (let [polys (->> (path/flatten-path segs ctm tolerance)
                       (keep (fn [{:keys [^doubles points]}]
                               (when (>= (alength points) 6) points))))]
        (raster/fill-polygons! canvas polys (:fill-rule props) (rgb->unit fill) opacity)))))

(defn- paint-stroke! [canvas segs ctm props]
  (let [stroke (:stroke props)
        opacity (:stroke-opacity props)
        width (double (:stroke-width props))]
    (when (and (vector? stroke) (> width 0.0) (> (double opacity) 0.0))
      (let [scale (m/scale-factor ctm)
            tol (/ tolerance scale)
            subpaths (path/flatten-path segs m/identity-matrix tol)
            pieces (stroke/stroke-polygons
                    subpaths {:width width
                              :cap (:stroke-linecap props)
                              :join (:stroke-linejoin props)
                              :miter-limit (:stroke-miterlimit props)
                              :tolerance tol})
            polys (map (fn [pts] (raster/orient-positive (m/transform-points ctm pts))) pieces)]
        (raster/fill-polygons! canvas polys :nonzero (rgb->unit stroke) opacity)))))

(defn- paint-shape! [canvas tag attrs ctm props]
  (when-let [segs (shape-path tag attrs)]
    (when (not= tag "line")
      (paint-fill! canvas segs ctm props))
    (paint-stroke! canvas segs ctm props)))

;; ---------------------------------------------------------------------------
;; The tree walk

(defn- collect-ids
  "Map of `id` -> element over the whole document, first one wins."
  [root]
  (letfn [(walk [ids el]
            (let [id (get (:attrs el) "id")
                  ids (if (and id (not (contains? ids id))) (assoc ids id el) ids)]
              (reduce walk ids (:children el))))]
    (walk {} root)))

(declare render-element!)

(defn- render-content!
  [{:keys [ids] :as env} canvas el ctm props depth]
  (let [{:keys [tag attrs children]} el]
    (cond
      (or (= tag "g") (= tag "svg"))
      (doseq [child children]
        (render-element! env canvas child ctm props (inc depth) false))

      (= tag "use")
      (let [href (get attrs "href")
            target (when (and href (.startsWith ^String href "#"))
                     (get ids (subs href 1)))]
        (when (and target (or (= (:tag target) "g") (shape-tags (:tag target))))
          (let [ctm' (m/multiply ctm (m/translate (len attrs "x" 0.0) (len attrs "y" 0.0)))]
            (render-element! env canvas target ctm' props (inc depth) false))))

      (shape-tags tag)
      (paint-shape! canvas tag attrs ctm props))))

(defn- render-element!
  [{:keys [width height] :as env} canvas el parent-ctm parent-props depth root?]
  (let [{:keys [tag attrs]} el]
    (when (and (<= depth max-depth)
               (or root? (container-tags tag) (shape-tags tag)))
      (let [style (p/parse-style (get attrs "style"))
            display (when-let [^String d (raw-property attrs style "display")] (.trim d))
            opacity (or (p/parse-opacity (raw-property attrs style "opacity")) 1.0)]
        (when (and (not= display "none") (> (double opacity) 0.0))
          (let [props (compute-properties parent-props attrs style)
                ctm (if root?
                      parent-ctm
                      (m/multiply parent-ctm (p/parse-transform (get attrs "transform"))))
                layer? (< (double opacity) 1.0)
                target (if layer? (raster/new-canvas width height) canvas)]
            (render-content! env target el ctm props depth)
            (when layer?
              (raster/composite-layer! canvas target (double opacity)))))))))

(defn- viewport-matrix
  "CTM0: maps the document's view box (or intrinsic size, or the output size)
  onto the `width` x `height` image, stretching if the aspect ratios differ."
  [attrs width height]
  (let [vb (p/parse-number-list (get attrs "viewBox" ""))
        w (p/parse-length (get attrs "width"))
        h (p/parse-length (get attrs "height"))
        [vx vy vw vh] (cond
                        (and (>= (count vb) 4) (> (double (vb 2)) 0.0) (> (double (vb 3)) 0.0))
                        (subvec vb 0 4)
                        (and w h (> (double w) 0.0) (> (double h) 0.0)) [0.0 0.0 w h]
                        :else [0.0 0.0 (double width) (double height)])
        sx (/ (double width) (double vw))
        sy (/ (double height) (double vh))]
    [sx 0.0 0.0 sy (- (* (double vx) sx)) (- (* (double vy) sy))]))

(defn render-document
  "Renders the parsed document `root` (see `svgraster.xml/parse`) onto a new
  transparent canvas of `width` x `height` pixels and returns it."
  [root width height]
  (let [canvas (raster/new-canvas width height)
        env {:ids (collect-ids root) :width width :height height}]
    (when (= (:tag root) "svg")
      (render-element! env canvas root (viewport-matrix (:attrs root) width height)
                       initial-properties 0 true))
    canvas))
