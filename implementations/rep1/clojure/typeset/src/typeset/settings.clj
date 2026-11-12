(ns typeset.settings
  "The `settings.cfg` file: parsing, validation, defaults and derived geometry."
  (:require [clojure.string :as str]
            [typeset.util :as u :refer [fail]]))

(set! *warn-on-reflection* true)

(def ^:private pt 1000)

;; ---------------------------------------------------------------------------
;; Value parsers. Each returns the value, or throws via the `bad` callback.

(def ^:private unit-mp {"" 1 "pt" 1000 "mm" 2835 "cm" 28350 "in" 72000 "pc" 12000})

(def ^:private ^BigInteger big-limit (BigInteger/valueOf (bit-shift-left 1 60)))

(defn- clamp [^BigInteger b]
  (cond (pos? (.compareTo b big-limit)) (.longValue big-limit)
        (neg? (.compareTo b (.negate big-limit))) (- (.longValue big-limit))
        :else (.longValue b)))

(defn parse-length
  "Parse a length literal to millipoints; nil when malformed."
  [^String s]
  (when-let [[_ neg whole frac unit] (re-matches #"(-?)(\d+)(?:\.(\d{1,3}))?(pt|mm|cm|in|pc)?" s)]
    (let [k (count frac)
          p10 (BigInteger/TEN)
          scale-k (.pow p10 k)
          n (.add (.multiply (BigInteger. ^String whole) scale-k)
                  (if frac (BigInteger. ^String frac) BigInteger/ZERO))
          v (.divide (.multiply n (BigInteger/valueOf (long (unit-mp (or unit ""))))) scale-k)]
      (clamp (if (= neg "-") (.negate v) v)))))

(defn parse-integer
  "Parse an integer literal; nil when malformed."
  [^String s]
  (when (re-matches #"-?\d+" s)
    (clamp (BigInteger. s))))

;; ---------------------------------------------------------------------------
;; Key table

(defn- k [type default & {:as opts}] (merge {:type type :default default} opts))

(def key-table
  "Setting name -> {:type :default [:min :max :words]}. A default of `nil`
  for `footer-baseline`, `footnote-max-height` and the `-even` slots is
  filled in after the explicit settings are known."
  (let [len  (fn [d & [mn mx]] (k :length d :min (or mn 0) :max mx))
        size (fn [d] (k :length d :min 1000 :max 200000))
        lead (fn [d] (k :length d :min 1000))
        int* (fn [d mn mx] (k :int d :min mn :max mx))
        bool (fn [d] (k :bool d))
        fam  (fn [d] (k :family d))
        aln  (fn [d] (k :enum (keyword d) :words ["justify" "left" "right" "center"]))
        txt  (fn [d & {:as o}] (merge (k :text d) o))
        heading-levels
        (apply merge
               (for [[n sz ld sb sa] [[1 20 24 18 9] [2 14 17 14 7] [3 12 14 12 6] [4 11 13 11 5]]]
                 {(str "h" n "-size") (size (* sz pt))
                  (str "h" n "-leading") (lead (* ld pt))
                  (str "h" n "-space-before") (len (* sb pt))
                  (str "h" n "-space-after") (len (* sa pt))}))
        slots (for [hf ["header" "footer"] pos ["left" "center" "right"]]
                (str hf "-" pos))]
    (merge
     {"page-width" (len 612000 36000) "page-height" (len 792000 36000)
      "margin-top" (len 72000) "margin-bottom" (len 72000)
      "margin-left" (len 72000) "margin-right" (len 72000)
      "header-baseline" (len 36000) "footer-baseline" (len nil)
      "page-start" (int* 1 1 3000)
      "body-font" (fam "serif") "body-size" (size 10000) "leading" (lead 12000)
      "line-skip" (len 1000) "align" (aln "justify")
      "par-indent" (len 18000) "par-space" (len 0)
      "tolerance" (int* 1000 0 10000) "line-penalty" (int* 10 0 10000)
      "hyphen-penalty" (int* 50 -9999 9999) "ex-hyphen-penalty" (int* 50 -9999 9999)
      "adj-demerits" (int* 10000 0 1000000)
      "double-hyphen-demerits" (int* 10000 0 1000000)
      "final-hyphen-demerits" (int* 5000 0 1000000)
      "ragged-stretch" (int* 3 0 100)
      "hyphenate" (bool true) "hyphen-patterns" (k :patterns "english")
      "heading-font" (fam "sans") "heading-bold" (bool true)
      "heading-italic" (bool false) "heading-align" (aln "left")
      "heading-number" (bool true) "heading-number-gap" (len 6000)
      "h1-newpage" (bool false)
      "list-indent" (len 18000) "list-marker-gap" (len 4000)
      "list-space" (len 6000) "list-item-space" (len 0)
      "quote-indent" (len 18000) "quote-space" (len 6000)
      "pre-font" (fam "mono") "pre-size" (size 9000) "pre-leading" (lead 11000)
      "pre-indent" (len 0) "pre-space" (len 6000)
      "table-col-gap" (len 8000) "table-row-space" (len 2000)
      "table-rule-space" (len 2000) "table-rule-thickness" (len 400 1)
      "table-space" (len 6000) "table-leading" (lead 12000)
      "rule-thickness" (len 500 1) "rule-space" (len 6000)
      "footnote-font" (fam "serif") "footnote-size" (size 8000)
      "footnote-leading" (lead 10000) "footnote-indent" (len 10000)
      "footnote-mark-gap" (len 2000) "footnote-mark-size" (size 6000)
      "footnote-mark-raise" (len 2000) "footnote-item-space" (len 2000)
      "footnote-rule-width" (len 120000) "footnote-rule-thickness" (len 400 1)
      "footnote-space-before" (len 6000) "footnote-space-after" (len 3000)
      "footnote-min-split" (int* 1 1 100)
      "footnote-max-height" (len nil 1000)
      "mark-size" (size 7000) "mark-raise" (len 3000)
      "figure-width" (len 0) "figure-frame" (bool true)
      "figure-caption-font" (fam "serif") "figure-caption-size" (size 9000)
      "figure-caption-leading" (lead 11000) "figure-caption-align" (aln "center")
      "figure-caption-space" (len 4000)
      "figure-caption-prefix" (txt "Figure" :literal true)
      "figure-caption-gap" (len 4000)
      "float-space-after" (len 12000) "float-min-body" (len 24000)
      "widows" (int* 2 1 20) "orphans" (int* 2 1 20) "keep-with-next" (bool true)
      "toc-depth" (int* 2 0 4) "toc-font" (fam "serif") "toc-size" (size 10000)
      "toc-leading" (lead 14000) "toc-indent" (len 18000)
      "toc-number-gap" (len 6000) "toc-reserve" (len 30000)
      "toc-leader" (txt "." :literal true :leader true)
      "toc-leader-gap" (len 3000) "toc-entry-space" (len 0)
      "toc-title" (txt "Contents" :literal true)
      "toc-title-font" (fam "sans") "toc-title-size" (size 20000)
      "toc-title-space-after" (len 12000)
      "header-font" (fam "sans") "header-size" (size 9000)}
     heading-levels
     (into {} (for [s slots] [s (txt [])]))
     (into {} (for [s slots] [(str s "-even") (txt nil :same-as s)])))))

(def ^:private geometry-keys
  ["page-width" "page-height" "margin-top" "margin-bottom" "margin-left" "margin-right"])

;; ---------------------------------------------------------------------------
;; Text values

(def ^:private placeholders #{"page" "pages" "title" "author" "date" "chapter" "section"})

(defn- scan-text
  "Single left-to-right scan of a text value (code points `v`). Returns a vector
  of segments (strings and placeholder keywords) or `[:error code index]`."
  [^ints v]
  (let [n (alength v)
        sb (StringBuilder.)]
    (loop [i 0 segs []]
      (letfn [(flush [] (let [s (str sb)] (.setLength sb 0) (if (seq s) (conj segs s) segs)))]
        (if (>= i n)
          (flush)
          (let [c (aget v i)]
            (cond
              (== c 92)
              (if (and (< (inc i) n) (#{123 125 92} (aget v (inc i))))
                (do (.appendCodePoint sb (aget v (inc i))) (recur (+ i 2) segs))
                [:error "bad-escape" i])

              (== c 123)
              (let [j (long (loop [j (inc i)] (cond (>= j n) -1 (== (aget v j) 125) j :else (recur (inc j)))))
                    nm (when (>= j 0) (u/cps->str v (inc i) j))]
                (if (and nm (placeholders nm))
                  (let [segs (flush)] (recur (inc j) (conj segs (keyword nm))))
                  [:error "unknown-placeholder" i]))

              (== c 125) [:error "stray-brace" i]

              :else (do (.appendCodePoint sb c) (recur (inc i) segs)))))))))

;; ---------------------------------------------------------------------------
;; Parsing

(defn- blank-char? [c] (or (== c 32) (== c 9)))

(defn- key-char? [c] (or (<= 97 c 122) (<= 48 c 57) (== c 45)))

(defn split-assignment
  "Shape of an assignment `[ \\t]* KEY [ \\t]* = VALUE` over the code points
  `cps`: returns `{:key :key-col :value-start :value-end}` (0-based indices of
  the trimmed value) or nil when the line has another shape."
  [^ints cps]
  (let [n (alength cps)
        i (loop [i 0] (if (and (< i n) (blank-char? (aget cps i))) (recur (inc i)) i))
        j (loop [j i] (if (and (< j n) (key-char? (aget cps j))) (recur (inc j)) j))]
    (when (> j i)
      (let [e (loop [e j] (if (and (< e n) (blank-char? (aget cps e))) (recur (inc e)) e))]
        (when (and (< e n) (== (aget cps e) 61))
          (let [vs (loop [p (inc e)] (if (and (< p n) (blank-char? (aget cps p))) (recur (inc p)) p))
                ve (loop [p n] (if (and (> p vs) (blank-char? (aget cps (dec p)))) (recur (dec p)) p))]
            {:key (u/cps->str cps i j) :key-col i :value-start vs :value-end (max vs ve)}))))))

(defn- parse-value
  "Parse and range-check value text `vs` of spec `spec`. Returns the value or
  `[:error code offset]` where offset is relative to the value start."
  [spec ^ints vcps]
  (let [s (u/cps->str vcps 0 (alength vcps))
        bad (fn [code] [:error code 0])
        in-range (fn [v] (and (or (nil? (:min spec)) (>= v (:min spec)))
                              (or (nil? (:max spec)) (<= v (:max spec)))))]
    (case (:type spec)
      :length (if-let [v (parse-length s)]
                (if (in-range v) v (bad "bad-value"))
                (bad "bad-length"))
      :int (if-let [v (parse-integer s)]
             (if (in-range v) v (bad "bad-value"))
             (bad "bad-integer"))
      :bool (case s "on" true "off" false (bad "bad-boolean"))
      :enum (if (some #{s} (:words spec)) (keyword s) (bad "bad-enum"))
      :family (if (#{"serif" "sans" "mono"} s) s (bad "unknown-font"))
      :patterns (if (#{"english" "minimal"} s) s (bad "unknown-patterns"))
      :text (let [segs (scan-text vcps)]
              (cond
                (and (vector? segs) (= :error (first segs))) segs
                (and (:literal spec) (some keyword? segs)) (bad "bad-value")
                (:leader spec)
                (let [lead (apply str segs)
                      cp-count (.codePointCount ^String lead 0 (.length ^String lead))]
                  (if (and (<= 1 cp-count 8) (not (str/includes? lead " ")))
                    lead
                    (bad "bad-value")))
                (:literal spec) (apply str segs)
                :else segs)))))

(defn- error? [v] (and (vector? v) (= :error (first v))))

(defn- default-of [spec] (:default spec))

(defn- resolve-defaults
  "Fill in the settings whose defaults depend on other settings and derive the
  page geometry."
  [m]
  (let [ph (m "page-height")
        pw (m "page-width")
        m (cond-> m (nil? (m "footer-baseline")) (assoc "footer-baseline" (- ph 36000)))
        body-w (- pw (m "margin-left") (m "margin-right"))
        body-h (- ph (m "margin-top") (m "margin-bottom"))
        m (cond-> m (nil? (m "footnote-max-height")) (assoc "footnote-max-height" (u/fdiv body-h 2)))
        m (reduce (fn [m [kk spec]]
                    (if (:same-as spec)
                      (cond-> m (nil? (m kk)) (assoc kk (m (:same-as spec))))
                      m))
                  m key-table)]
    (assoc m
           :body-x (m "margin-left") :body-y (m "margin-top")
           :body-width body-w :body-height body-h
           :body-bottom (+ (m "margin-top") body-h))))

(defn parse
  "Parse the text of a settings file (nil for an absent file) into a settings
  map keyed by setting name (strings) plus the derived `:body-*` keys. Throws
  an input error for the first problem."
  [text]
  (let [file "settings.cfg"
        lines (if text (str/split text #"\n" -1) [])
        lines (if (and (seq lines) (= "" (peek lines))) (pop lines) lines)
        init (into {} (for [[kk spec] key-table :when (some? (default-of spec))]
                        [kk (default-of spec)]))]
    (loop [ln 1 ls (seq lines) m init seen {} last-geom nil]
      (if-let [line (first ls)]
        (let [cps (u/code-points ^String line)
              n (alength cps)
              first-nb (loop [i 0] (if (and (< i n) (blank-char? (aget cps i))) (recur (inc i)) i))]
          (cond
            (or (== first-nb n) (== (aget cps first-nb) 35))
            (recur (inc ln) (next ls) m seen last-geom)

            :else
            (let [a (split-assignment cps)]
              (when-not a (fail file ln (inc first-nb) "bad-syntax"))
              (let [kk (:key a)
                    spec (get key-table kk)
                    _ (when-not spec (fail file ln (inc (:key-col a)) "unknown-setting"))
                    _ (when (contains? seen kk) (fail file ln (inc (:key-col a)) "duplicate-setting"))
                    vs (:value-start a)
                    vcol (inc vs)
                    vcps (java.util.Arrays/copyOfRange cps (int vs) (int (:value-end a)))
                    ;; an empty value reports at the end of line position
                    vcol (if (zero? (alength vcps)) (inc n) vcol)
                    v (parse-value spec vcps)]
                (when (error? v)
                  (fail file ln (+ vcol (long (nth v 2))) (nth v 1)))
                (recur (inc ln) (next ls)
                       (assoc m kk v) (assoc seen kk [ln vcol])
                       (if (some #{kk} geometry-keys) kk last-geom))))))
        ;; all lines read: geometry check
        (let [m (resolve-defaults m)]
          (when (or (< (:body-width m) 36000) (< (:body-height m) 36000))
            (if last-geom
              (let [[l c] (seen last-geom)] (fail file l c "bad-value"))
              (fail file 0 0 "bad-value")))
          m)))))
