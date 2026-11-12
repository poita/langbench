(ns mime.part
  "Builds the MIME part tree of a message and numbers its parts."
  (:require [mime.bytes :as bytes]
            [mime.charset :as charset]
            [mime.header :as header]
            [mime.params :as params]
            [mime.text :as text]
            [mime.transfer :as transfer]))

(set! *warn-on-reflection* true)

(def ^:private non-token-chars
  #{\space \tab \( \) \< \> \@ \, \; \: \\ \" \/ \[ \] \? \=})

(defn- token? [^String s]
  (and (pos? (.length s)) (not-any? non-token-chars s)))

(defn- parse-media-type
  "Splits a lower-cased Content-Type value into `[type subtype]` when it is
  a well-formed `type/subtype`, else nil."
  [^String v]
  (let [slash (.indexOf v "/")]
    (when (pos? slash)
      (let [t (.substring v 0 slash)
            s (.substring v (inc slash))]
        (when (and (token? t) (token? s))
          [t s])))))

(defn- delimiter-kind
  "Classifies the line `[from, to)` of `body` against the boundary bytes
  `bb`: :close, :open or nil when it is not a delimiter line."
  [^bytes body ^long from ^long to ^bytes bb]
  (let [blen (alength bb)
        p (+ from 2 blen)]
    (when (and (<= p to)
               (== (aget body from) 45) (== (aget body (inc from)) 45)
               (loop [k 0]
                 (cond (== k blen) true
                       (== (aget body (+ from 2 k)) (aget bb k)) (recur (inc k))
                       :else false)))
      (let [blank-tail? (fn [^long start]
                          (loop [i start]
                            (cond (>= i to) true
                                  (let [x (aget body i)] (or (== x 32) (== x 9))) (recur (inc i))
                                  :else false)))]
        (cond
          (and (<= (+ p 2) to) (== (aget body p) 45) (== (aget body (inc p)) 45)
               (blank-tail? (+ p 2))) :close
          (blank-tail? p) :open
          :else nil)))))

(defn- trim-lf-end
  "End index for the region `[from, to)` after dropping one trailing LF."
  ^long [^bytes body ^long from ^long to]
  (if (and (> to from) (== (aget body (dec to)) 10)) (dec to) to))

(defn split-multipart
  "Splits the body bytes of a multipart part at the delimiter lines for the
  boundary bytes `bb`. Returns
  `{:preamble n :epilogue n-or-nil :children [bytes ...]}`."
  [^bytes body ^bytes bb]
  (let [n (alength body)]
    (loop [pos 0 children [] cstart -1 preamble 0]
      (if (>= pos n)
        (if (neg? cstart)
          {:preamble n :epilogue nil :children []}
          {:preamble preamble :epilogue nil
           :children (conj children (bytes/sub body cstart (trim-lf-end body cstart n)))})
        (let [le (bytes/index-of-lf body pos n)
              nxt (min n (inc le))
              kind (delimiter-kind body pos le bb)]
          (cond
            (nil? kind) (recur nxt children cstart preamble)

            (neg? cstart)
            (let [pre (trim-lf-end body 0 pos)]
              (if (= kind :close)
                {:preamble pre :epilogue (- n nxt) :children []}
                (recur nxt children nxt pre)))

            :else
            (let [children (conj children (bytes/sub body cstart (trim-lf-end body cstart pos)))]
              (if (= kind :close)
                {:preamble preamble :epilogue (- n nxt) :children children}
                (recur nxt children nxt preamble)))))))))

(defn parse-part
  "Parses `data` (a part's bytes, LF line endings) into a tree node. `parent-type`
  is the effective `type/subtype` of the enclosing part, or nil.

  A node is a map with `:fields`, `:type`, `:subtype`, `:cte`, `:disposition`
  (nil without a Content-Disposition header), `:filename`, `:kind`
  (:multipart, :message or :leaf) and `:children`. Multipart nodes also have
  `:boundary`, `:preamble` and `:epilogue`; leaves have `:content` and, for
  `text/*`, `:charset`."
  [^bytes data parent-type]
  (let [{:keys [fields body-start]} (header/parse-block data)
        body (bytes/sub data body-start (alength data))
        ct-field (header/find-field fields "content-type")
        ct (when ct-field (params/parse (:raw ct-field)))
        [type subtype] (or (when ct (parse-media-type (:value ct)))
                           (if (= parent-type "multipart/digest")
                             ["message" "rfc822"]
                             ["text" "plain"]))
        ct-params (:params ct {})
        cd-field (header/find-field fields "content-disposition")
        cd (when cd-field (params/parse (:raw cd-field)))
        cte-field (header/find-field fields "content-transfer-encoding")
        cte (if cte-field (:value (params/parse (:raw cte-field))) "7bit")
        disposition (when cd (if (= (:value cd) "") "inline" (:value cd)))
        filename (or (get (:params cd) "filename") (get ct-params "name"))
        boundary (get ct-params "boundary")
        media (str type "/" subtype)
        base {:fields fields :type type :subtype subtype :cte cte
              :disposition disposition :filename filename}]
    (cond
      (and (= type "multipart") (some? boundary) (seq boundary))
      (let [{:keys [preamble epilogue children]} (split-multipart body (charset/encode-utf8 boundary))]
        (assoc base :kind :multipart :boundary boundary
               :preamble preamble :epilogue epilogue
               :children (mapv #(parse-part % media) children)))

      (= media "message/rfc822")
      (assoc base :kind :message
             :children [(parse-part (transfer/decode-body body cte) media)])

      :else
      (cond-> (assoc base :kind :leaf :children []
                     :content (transfer/decode-body body cte))
        (= type "text") (assoc :charset (if (contains? ct-params "charset")
                                          (charset/normalize-name (get ct-params "charset"))
                                          "us-ascii"))))))

(defn flatten-parts
  "Numbers the nodes of the tree rooted at `root` in depth-first pre-order.
  Returns a vector of nodes, each with `:index`, `:depth` and `:child-count`
  added and `:children` removed."
  [root]
  (letfn [(walk [acc node depth]
            (let [idx (count acc)
                  acc (conj! acc (-> node
                                     (dissoc :children)
                                     (assoc :index idx :depth depth
                                            :child-count (count (:children node)))))]
              (reduce (fn [a c] (walk a c (inc depth))) acc (:children node))))]
    (persistent! (walk (transient []) root 0))))
