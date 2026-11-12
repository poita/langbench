(ns mime.params
  "Structured header values (`Content-Type`, `Content-Disposition`,
  `Content-Transfer-Encoding`): a main value followed by `;`-separated
  parameters, including RFC 2231 continuations and extended values."
  (:require [mime.charset :as charset]
            [mime.rfc2047 :as rfc2047]
            [mime.text :as text])
  (:import (java.io ByteArrayOutputStream)))

(set! *warn-on-reflection* true)

(defn split-segments
  "Splits `s` at every `;` that is not inside a quoted string. Returns a
  vector of substrings (the quotes are kept)."
  [^String s]
  (let [n (.length s)]
    (loop [i 0 start 0 out []]
      (if (>= i n)
        (conj out (.substring s (int start) n))
        (let [c (.charAt s i)]
          (cond
            (= c \") (recur (long (second (text/scan-quoted s i))) start out)
            (= c \;) (recur (inc i) (inc i) (conj out (.substring s (int start) (int i))))
            :else (recur (inc i) start out)))))))

(defn- raw-param
  "Parses one parameter segment into `[name value]`, or nil without an `=`."
  [^String seg]
  (let [eq (.indexOf seg "=")]
    (when (>= eq 0)
      (let [name (text/lower (text/strip (.substring seg 0 eq)))
            v (text/strip (.substring seg (inc eq)))
            v (if (and (pos? (.length v)) (= (.charAt v 0) \"))
                (first (text/scan-quoted v 0))
                v)]
        [name v]))))

(defn- classify-name
  "Classifies a raw parameter name:
  `[:segment base n extended?]` for `base*N` / `base*N*`,
  `[:extended base]` for `base*`, and `[:plain name]` otherwise."
  [^String name]
  (let [len (.length name)
        ext? (and (pos? len) (= (.charAt name (dec len)) \*))
        core-end (if ext? (dec len) len)
        dstart (loop [k core-end]
                 (if (and (pos? k)
                          (let [c (.charAt name (dec k))] (and (>= (int c) 48) (<= (int c) 57))))
                   (recur (dec k))
                   k))]
    (cond
      (and (< dstart core-end) (>= (dec dstart) 1) (= (.charAt name (dec dstart)) \*))
      [:segment (.substring name 0 (dec dstart))
       (BigInteger. (.substring name (int dstart) (int core-end))) ext?]

      (and ext? (> len 1))
      [:extended (.substring name 0 (dec len))]

      :else [:plain name])))

(defn- split-extended
  "Splits an extended value `charset'language'text` into `[charset text]`."
  [^String v]
  (let [i1 (.indexOf v "'")
        i2 (if (neg? i1) -1 (.indexOf v "'" (int (inc i1))))]
    (if (neg? i2)
      ["us-ascii" v]
      (let [cs (.substring v 0 i1)]
        [(if (zero? (.length cs)) "us-ascii" cs) (.substring v (int (inc i2)))]))))

(defn- decode-extended
  [^String v]
  (let [[cs t] (split-extended v)]
    (charset/decode (text/percent-decode t) cs)))

(defn- assemble-segments
  "Builds the value of a parameter from its numbered segments, a sorted map
  from N to `[extended? value]`."
  [segs]
  (let [out (ByteArrayOutputStream.)
        seg0 (get segs BigInteger/ZERO)
        cs (if (and seg0 (first seg0))
             (first (split-extended (second seg0)))
             "us-ascii")]
    (doseq [[n [ext? v]] segs]
      (let [v ^String v]
        (.write out
                ^bytes (cond
                         (not ext?) (charset/encode-utf8 v)
                         (and (zero? (.signum ^BigInteger n)))
                         (text/percent-decode (second (split-extended v)))
                         :else (text/percent-decode v)))))
    (charset/decode (.toByteArray out) cs)))

(defn- assemble
  "Applies the RFC 2231 rules to the ordered raw parameters
  (a seq of `[name value]`, first occurrence of a name winning) and returns a
  map from effective parameter name to its decoded value."
  [raw]
  (let [groups
        (reduce
         (fn [m [name value]]
           (let [[kind base n ext?] (classify-name name)]
             (case kind
               :segment (update-in m [base :segs]
                                   (fn [segs]
                                     (let [segs (or segs (sorted-map))]
                                       (if (contains? segs n) segs (assoc segs n [ext? value])))))
               :extended (update m base #(if (contains? % :ext) % (assoc % :ext value)))
               :plain (update m base #(if (contains? % :plain) % (assoc % :plain value))))))
         {} raw)]
    (reduce-kv
     (fn [out base {:keys [segs ext plain]}]
       (assoc out base
              (cond segs (assemble-segments segs)
                    ext (decode-extended ext)
                    :else (rfc2047/decode-unstructured plain))))
     {} groups)))

(defn parse
  "Parses the unfolded raw value `raw` of a structured header.

  Returns `{:value v :params {name value}}` where `v` is the first segment,
  stripped and lower-cased, and `:params` maps each lower-cased effective
  parameter name to its decoded value (RFC 2231 continuations assembled)."
  [^String raw]
  (let [[first-seg & rest-segs] (split-segments raw)
        params (loop [segs rest-segs seen #{} out []]
                 (if-let [seg (first segs)]
                   (let [p (raw-param seg)]
                     (if (and p (not (contains? seen (first p))))
                       (recur (next segs) (conj seen (first p)) (conj out p))
                       (recur (next segs) seen out)))
                   out))]
    {:value (text/lower (text/strip first-seg))
     :params (assemble params)}))
