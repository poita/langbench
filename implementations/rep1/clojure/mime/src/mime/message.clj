(ns mime.message
  "Parses one whole message into a plain data structure: headers, addresses,
  date, the flattened part list, body selection and attachments."
  (:require [mime.address :as address]
            [mime.bytes :as bytes]
            [mime.charset :as charset]
            [mime.date :as date]
            [mime.header :as header]
            [mime.part :as part]))

(set! *warn-on-reflection* true)

(def address-headers
  "The header names parsed as address lists, in output order."
  ["from" "sender" "reply-to" "to" "cc" "bcc"])

(defn- body-candidate? [node]
  (and (= (:kind node) :leaf)
       (not= (:disposition node) "attachment")))

(defn select-bodies
  "Given the flat part list, returns `{:text idx-or-nil :html idx-or-nil}`:
  the first body candidates of type text/plain and text/html. The walk does
  not descend into a message/rfc822 container's child."
  [parts]
  (loop [ps (seq parts) skip-depth nil text nil html nil]
    (if-let [p (first ps)]
      (cond
        (and skip-depth (> (:depth p) skip-depth)) (recur (next ps) skip-depth text html)
        :else
        (let [skip (when (= (:kind p) :message) (:depth p))
              cand? (body-candidate? p)
              media [(:type p) (:subtype p)]]
          (recur (next ps) skip
                 (if (and (nil? text) cand? (= media ["text" "plain"])) (:index p) text)
                 (if (and (nil? html) cand? (= media ["text" "html"])) (:index p) html))))
      {:text text :html html})))

(defn- annotate-leaf
  [node role]
  (let [content ^bytes (:content node)]
    (assoc node
           :role role
           :size (alength content)
           :adler32 (bytes/adler32 content))))

(defn part-text
  "The decoded text of a `text/*` leaf part."
  ^String [part]
  (charset/decode (:content part) (:charset part)))

(defn parse
  "Parses the message bytes `raw` into a map:

  - `:size`        byte length of `raw`
  - `:fields`      the header fields (`{:name :key :raw}`), in order
  - `:addresses`   map from address header name to a vector of `{:display :spec}`
  - `:date`        nil without a Date header, else `{:raw s :valid? b ...}` plus
                   `:epoch`, `:utc` and `:offset` when valid
  - `:parts`       flat vector of parts in pre-order (see [[mime.part/parse-part]]),
                   each with `:index`, `:depth`, and for leaves `:role`
                   (:text, :html or :attachment), `:size` and `:adler32`
  - `:text`, `:html`  the index of the selected body parts, or nil
  - `:attachments` the attachment parts, in order."
  [^bytes raw]
  (let [data (bytes/normalize-eol raw)
        root (part/parse-part data nil)
        fields (:fields root)
        flat (part/flatten-parts root)
        {:keys [text html]} (select-bodies flat)
        parts (mapv (fn [p]
                      (if (= (:kind p) :leaf)
                        (annotate-leaf p (cond (= (:index p) text) :text
                                               (= (:index p) html) :html
                                               :else :attachment))
                        p))
                    flat)
        date-field (header/find-field fields "date")]
    {:size (alength raw)
     :fields fields
     :addresses (into {}
                      (map (fn [name]
                             [name (into [] (comp (filter #(= (:key %) name))
                                                  (mapcat #(address/parse-list (:raw %))))
                                         fields)]))
                      address-headers)
     :date (when date-field
             (let [raw-v (:raw date-field)
                   parsed (date/parse raw-v)]
               (merge {:raw raw-v :valid? (some? parsed)} parsed)))
     :parts parts
     :text text
     :html html
     :attachments (filterv #(= (:role %) :attachment) parts)}))
