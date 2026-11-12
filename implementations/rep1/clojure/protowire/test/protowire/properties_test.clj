(ns protowire.properties-test
  (:require [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [protowire.core :as pw]
            [protowire.test-util :refer [all-types-schema]]))

(def ^:private s64 (gen/large-integer* {:min Long/MIN_VALUE :max Long/MAX_VALUE}))
(def ^:private s32 (gen/large-integer* {:min Integer/MIN_VALUE :max Integer/MAX_VALUE}))
(def ^:private u32 (gen/large-integer* {:min 0 :max 4294967295}))
(def ^:private u64 (gen/fmap (fn [n] (if (neg? n) (+ n 18446744073709551616N) n)) s64))
(def ^:private u64* (gen/fmap #(if (instance? clojure.lang.BigInt %) % (long %)) u64))
(def ^:private text (gen/fmap #(apply str %) (gen/vector gen/char 0 12)))
(def ^:private valid-text
  (gen/such-that #(= % (String. (.getBytes ^String % "UTF-8") "UTF-8")) text 100))
(def ^:private blob (gen/fmap byte-array (gen/vector (gen/fmap unchecked-byte (gen/choose 0 255)) 0 8)))

(defn- opt [k g] (gen/one-of [(gen/return {}) (gen/fmap (fn [v] {k v}) g)]))
(defn- vec-of [g] (gen/vector g 0 5))

(defn- node-gen [depth]
  (let [leaf-fields [(opt :i32 s32) (opt :i64 s64) (opt :u32 u32) (opt :u64 u64*)
                     (opt :s32 s32) (opt :s64 s64) (opt :b gen/boolean)
                     (opt :f32 u32) (opt :sf32 s32) (opt :f64 u64*) (opt :sf64 s64)
                     (opt :s valid-text) (opt :y blob)
                     (opt :ri32 (vec-of s32)) (opt :ru64 (vec-of u64*)) (opt :rs64 (vec-of s64))
                     (opt :rb (vec-of gen/boolean)) (opt :rf32 (vec-of u32)) (opt :rsf64 (vec-of s64))
                     (opt :rs (vec-of valid-text)) (opt :ry (vec-of blob))]
        nested (if (pos? depth)
                 [(opt :child (node-gen (dec depth)))
                  (opt :rn (vec-of (node-gen (dec depth))))]
                 [])]
    (gen/fmap #(apply merge %) (apply gen/tuple (concat leaf-fields nested)))))

(defn- normalise
  "Reduces a message to what survives an encode/decode round trip: byte arrays
  become vectors, default scalars and empty lists are dropped."
  [m]
  (into {}
        (keep (fn [[k v]]
                (let [v (cond (bytes? v) (vec v)
                              (map? v) (normalise v)
                              (and (sequential? v) (seq v))
                              (mapv #(cond (bytes? %) (vec %) (map? %) (normalise %) :else %) v)
                              :else v)]
                  (when-not (or (contains? #{0 false "" []} v) (and (sequential? v) (empty? v)))
                    [k v]))))
        m))

(defspec encode-decode-roundtrip 200
  (prop/for-all [m (node-gen 2)]
    (let [bs (pw/encode all-types-schema "Node" m)]
      (= (normalise m) (normalise (pw/decode all-types-schema "Node" bs))))))

(defspec encoding-is-canonical 200
  (prop/for-all [m (node-gen 2)]
    (let [hex (pw/encode-hex all-types-schema "Node" m)
          again (pw/encode-hex all-types-schema "Node"
                               (pw/decode-hex all-types-schema "Node" hex))]
      (= hex again))))

(defspec text-roundtrip 200
  (prop/for-all [m (node-gen 2)]
    (let [bs (pw/encode all-types-schema "Node" m)
          d (pw/decode all-types-schema "Node" bs)
          txt (pw/format-text all-types-schema "Node" d)]
      (= (seq bs) (seq (pw/encode all-types-schema "Node" (pw/parse-text all-types-schema "Node" txt)))))))

(defspec decoder-never-crashes 300
  (prop/for-all [bs (gen/fmap byte-array (gen/vector (gen/fmap unchecked-byte (gen/choose 0 255)) 0 40))]
    (try (pw/decode all-types-schema "Node" bs) true
         (catch clojure.lang.ExceptionInfo e (pw/error? e)))))
