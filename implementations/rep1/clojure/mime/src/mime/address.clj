(ns mime.address
  "Address-list parsing (`From`, `To`, `Cc`, ...): a tokeniser, a splitter
  into list elements and a matcher for `[phrase] <addr-spec>` and bare
  addr-specs. Parsing is lenient: an element that does not look like an
  address is kept as one address whose spec is its tokens run together."
  (:require [clojure.string :as str]
            [mime.rfc2047 :as rfc2047]
            [mime.text :as text]))

(set! *warn-on-reflection* true)

(def ^:private specials #{\< \> \@ \, \: \; \.})
(def ^:private atom-stops
  #{\space \tab \( \) \< \> \[ \] \@ \, \: \; \. \" \\})

(defn tokenize
  "Tokenises the raw header value `v` into a vector of
  `{:type t :text s :start i}` maps. `:type` is one of :atom, :quoted,
  :literal, :encoded and :special; `:start` is the index in `v` of the token's
  first character. Whitespace and comments produce no tokens."
  [^String v]
  (let [n (.length v)]
    (loop [i 0 out (transient [])]
      (if (>= i n)
        (persistent! out)
        (let [c (.charAt v i)]
          (cond
            (text/ws? c) (recur (inc i) out)

            (= c \() (recur (text/skip-comment v i) out)

            (= c \")
            (let [[content end] (text/scan-quoted v i)]
              (recur (long end) (conj! out {:type :quoted :text content :start i})))

            (= c \[)
            (let [end (loop [j (inc i)]
                        (if (>= j n)
                          n
                          (let [d (.charAt v j)]
                            (cond (= d \\) (recur (+ j 2))
                                  (= d \]) (inc j)
                                  :else (recur (inc j))))))
                  end (min end n)]
              (recur (long end) (conj! out {:type :literal :text (.substring v (int i) (int end)) :start i})))

            :else
            (if-let [[end t] (when (= c \=) (rfc2047/encoded-word-at v i))]
              (recur (long end) (conj! out {:type :encoded :text t :start i}))
              (cond
                (contains? specials c)
                (recur (inc i) (conj! out {:type :special :text (str c) :start i}))

                (contains? #{\) \] \\} c)
                (recur (inc i) (conj! out {:type :atom :text (str c) :start i}))

                :else
                (let [end (loop [j (inc i)]
                            (if (and (< j n) (not (contains? atom-stops (.charAt v j))))
                              (recur (inc j))
                              j))]
                  (recur (long end) (conj! out {:type :atom :text (.substring v (int i) (int end)) :start i})))))))))))

(defn- special? [tok s]
  (and (= (:type tok) :special) (= (:text tok) s)))

(defn split-elements
  "Splits the token vector at top-level commas (those outside any `<...>`,
  tracked with a counter that never drops below zero). Returns a vector of
  token vectors."
  [tokens]
  (loop [ts (seq tokens) depth 0 cur [] out []]
    (if-let [t (first ts)]
      (cond
        (special? t "<") (recur (next ts) (inc depth) (conj cur t) out)
        (special? t ">") (recur (next ts) (max 0 (dec depth)) (conj cur t) out)
        (and (special? t ",") (zero? depth)) (recur (next ts) depth [] (conj out cur))
        :else (recur (next ts) depth (conj cur t) out))
      (conj out cur))))

(defn- alternating?
  "True when `toks` is a non-empty run of tokens accepted by `ok?` separated
  by single `.` tokens, starting and ending with a non-dot token."
  [toks ok?]
  (and (seq toks)
       (odd? (count toks))
       (every? identity
               (map-indexed (fn [i t] (if (even? i) (ok? t) (special? t "."))) toks))))

(defn- render-addr-spec
  "Returns the rendering of the token run `toks` as an addr-spec, or nil when
  it does not have the shape `local [@ domain]`."
  [toks]
  (let [at (first (keep-indexed (fn [i t] (when (special? t "@") i)) toks))
        local (if at (subvec toks 0 at) toks)
        domain (when at (subvec toks (inc at)))
        local-ok (alternating? local #(#{:atom :quoted} (:type %)))
        texts (fn [ts] (str/join "." (map :text (take-nth 2 ts))))]
    (cond
      (not local-ok) nil
      (nil? at) (texts local)
      (and (= 1 (count domain)) (= :literal (:type (first domain))))
      (str (texts local) "@" (:text (first domain)))
      (alternating? domain #(= :atom (:type %)))
      (str (texts local) "@" (texts domain))
      :else nil)))

(defn- drop-group
  "Drops the tokens up to and including the first `:` when it comes before
  any `<` or `@` token."
  [toks]
  (let [idx (first (keep-indexed
                    (fn [i t]
                      (when (and (= (:type t) :special) (#{":" "<" "@"} (:text t))) [i (:text t)]))
                    toks))]
    (if (and idx (= (second idx) ":"))
      (subvec toks (inc (first idx)))
      toks)))

(defn- parse-element
  "Parses one element's tokens into `{:display d :spec s}` or nil."
  [^String v toks]
  (let [toks (drop-group toks)
        toks (if (and (seq toks) (special? (peek toks) ";")) (pop toks) toks)]
    (when (seq toks)
      (let [lt (first (keep-indexed (fn [i t] (when (special? t "<") i)) toks))
            gt (last (keep-indexed (fn [i t] (when (special? t ">") i)) toks))
            fallback (fn [] {:display "" :spec (apply str (map :text toks))})]
        (if lt
          (if (and gt (> gt lt))
            (if-let [spec (render-addr-spec (subvec toks (inc lt) gt))]
              {:display (if (zero? lt)
                          ""
                          (rfc2047/decode-display
                           (.substring v (int (:start (first toks))) (int (:start (toks lt))))))
               :spec spec}
              (fallback))
            (fallback))
          (if-let [spec (render-addr-spec toks)]
            {:display "" :spec spec}
            (fallback)))))))

(defn parse-list
  "Parses the raw value `v` of an address header into a vector of
  `{:display d :spec s}` maps."
  [^String v]
  (into [] (keep #(parse-element v %)) (split-elements (tokenize v))))
